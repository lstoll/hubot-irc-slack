# Hubot dependencies
{Robot, Adapter, TextMessage, EnterMessage, LeaveMessage, Response} = require 'hubot'
https = require 'https'

# Custom Response class that adds a sendPrivate method
class IrcResponse extends Response
  sendPrivate: (strings...) ->
    @robot.adapter.sendPrivate @envelope, strings...

# Irc library
Irc = require 'irc'

Log = require('log')
logger = new Log process.env.HUBOT_LOG_LEVEL or 'info'

class IrcBot extends Adapter

  send: (envelope, strings...) ->
    logger.info "Sending message"
    # channel = envelope.reply_to || @channelMapping[envelope.room] || envelope.room
    channel = envelope.reply_to || envelope.room

    channel = 'opsbot-dev'

    console.log "channel #{channel}"
    console.log "target #{@_getTargetFromEnvelope envelope}"


    strings.forEach (str) =>
      logger.debug "gonna say #{str}"
      str = @_escapeHtml str
      args = JSON.stringify
        username   : @options.nick
        channel    : channel
        text       : str
        link_names : @options.link_names if @options?.link_names?

      logger.debug "gonna call post with #{str}"
      @_post "/api/chat.postMessage", args


  # TODO - this may be handy for 'secret stuff?'
  # sendPrivate: (envelope, strings...) ->
  #   # Remove the room from the envelope and send as private message to user
  #
  #   if envelope.room
  #     delete envelope.room
  #
  #   if envelope.user?.room
  #     delete envelope.user.room
  #
  #   @send envelope, strings...
  # send: (envelope, strings...) ->
  #   # Use @notice if SEND_NOTICE_MODE is set
  #   return @notice envelope, strings if process.env.HUBOT_IRC_SEND_NOTICE_MODE?
  #
  #   target = @_getTargetFromEnvelope envelope
  #
  #   unless target
  #     return logger.error "ERROR: Not sure who to send to. envelope=", envelope
  #
  #   for str in strings
  #     @bot.say target, str

  # TODO - implement reply
  # reply: (envelope, strings...) ->
  #   for str in strings
  #     @send envelope.user, "#{envelope.user.name}: #{str}"

  join: (channel) ->
    self = @
    @bot.join channel, () ->
      logger.info('joined %s', channel)

      selfUser = self.getUserFromName self.robot.name
      self.receive new EnterMessage(selfUser)

  part: (channel) ->
    self = @
    @bot.part channel, () ->
      logger.info('left %s', channel)

      selfUser = self.getUserFromName self.robot.name
      self.receive new LeaveMessage(selfUser)

  getUserFromName: (name) ->
    return @robot.brain.userForName(name) if @robot.brain?.userForName?

    # Deprecated in 3.0.0
    return @userForName name

  getUserFromId: (id) ->
    # TODO: Add logic to convert object if name matches
    return @robot.brain.userForId(id) if @robot.brain?.userForId?

    # Deprecated in 3.0.0
    return @userForId id

  createUser: (channel, from) ->
    user = @getUserFromId from
    user.name = from

    if channel.match(/^[&#]/)
      user.room = channel
    else
      user.room = null
    user

  checkCanStart: ->
    if not process.env.HUBOT_IRC_NICK and not @robot.name
      throw new Error("HUBOT_IRC_NICK is not defined; try: export HUBOT_IRC_NICK='mybot'")
    else if not process.env.HUBOT_IRC_ROOMS
      throw new Error("HUBOT_IRC_ROOMS is not defined; try: export HUBOT_IRC_ROOMS='#myroom'")
    else if not process.env.HUBOT_IRC_SERVER
      throw new Error("HUBOT_IRC_SERVER is not defined: try: export HUBOT_IRC_SERVER='irc.myserver.com'")

  run: ->
    self = @

    do @checkCanStart

    options =
      nick:     process.env.HUBOT_IRC_NICK or @robot.name
      realName: process.env.HUBOT_IRC_REALNAME
      port:     process.env.HUBOT_IRC_PORT
      rooms:    process.env.HUBOT_IRC_ROOMS.split(",")
      server:   process.env.HUBOT_IRC_SERVER
      password: process.env.HUBOT_IRC_PASSWORD
      fakessl:  process.env.HUBOT_IRC_SERVER_FAKE_SSL?
      certExpired: process.env.HUBOT_IRC_SERVER_CERT_EXPIRED?
      debug:    process.env.HUBOT_IRC_DEBUG?
      usessl:   process.env.HUBOT_IRC_USESSL?
      userName: process.env.HUBOT_IRC_USERNAME

      # Slack section
      token : process.env.HUBOT_SLACK_TOKEN
      team  : process.env.HUBOT_SLACK_TEAM
      link_names: process.env.HUBOT_SLACK_LINK_NAMES or 0

    @options = options

    client_options =
      userName: options.userName
      realName: options.realName
      password: options.password
      debug: options.debug
      port: options.port
      stripColors: true
      secure: options.usessl
      selfSigned: options.fakessl
      certExpired: options.certExpired

    client_options['channels'] = options.rooms unless options.nickpass

    # Override the response to provide a sendPrivate method
    @robot.Response = IrcResponse

    @robot.name = options.nick
    bot = new Irc.Client options.server, options.nick, client_options

    next_id = 1
    user_id = {}

    bot.addListener 'names', (channel, nicks) ->
      for nick of nicks
        self.createUser channel, nick

    bot.addListener 'message', (from, to, message) ->
      if options.nick.toLowerCase() == to.toLowerCase()
        # this is a private message, let the 'pm' listener handle it
        return

      logger.debug "From #{from} to #{to}: #{message}"

      user = self.createUser to, from
      if user.room
        logger.info "#{to} <#{from}> #{message}"
      else
        unless message.indexOf(to) == 0
          message = "#{to}: #{message}"
        logger.debug "msg <#{from}> #{message}"
      self.receive new TextMessage(user, message)

    bot.addListener 'error', (message) ->
      logger.error('ERROR: %s: %s', message.command, message.args.join(' '))

    bot.addListener 'pm', (nick, message) ->
      logger.info('Got private message from %s: %s', nick, message)

      if process.env.HUBOT_IRC_PRIVATE
        return

      nameLength = options.nick.length
      if message.slice(0, nameLength).toLowerCase() != options.nick.toLowerCase()
        message = "#{options.nick} #{message}"

      self.receive new TextMessage({reply_to: nick, name: nick}, message)

    bot.addListener 'join', (channel, who) ->
      logger.info('%s has joined %s', who, channel)
      user = self.createUser channel, who
      user.room = channel
      self.receive new EnterMessage(user)

    bot.addListener 'part', (channel, who, reason) ->
      logger.info('%s has left %s: %s', who, channel, reason)
      user = self.createUser '', who
      user.room = channel
      msg = new LeaveMessage user
      msg.text = reason
      self.receive msg

    bot.addListener 'quit', (who, reason, channels) ->
      logger.info '%s has quit: %s (%s)', who, channels, reason
      for ch in channels
        user = self.createUser '', who
        user.room = ch
        msg = new LeaveMessage user
        msg.text = reason
        self.receive msg

    @bot = bot

    self.emit "connected"

  _getTargetFromEnvelope: (envelope) ->
    user = null
    room = null
    target = null

    # as of hubot 2.4.2, the first param to send() is an object with 'user'
    # and 'room' data inside. detect the old style here.
    if envelope.reply_to
      user = envelope
    else
      # expand envelope
      user = envelope.user
      room = envelope.room

    if user
      # most common case - we're replying to a user in a room
      if user.room
        target = user.room
      # reply directly
      else if user.name
        target = user.name
      # replying to pm
      else if user.reply_to
        target = user.reply_to
      # allows user to be an id string
      else if user.search?(/@/) != -1
        target = user
    else if room
      # this will happen if someone uses robot.messageRoom(jid, ...)
      target = room

    target

  ###################################################################
  # Convenience HTTP Methods for sending data back to slack.
  ###################################################################
  _get: (path, callback) ->
    @_request "GET", path, null, callback

  _post: (path, body, callback) ->
    logger.debug "POST called with #{body}"
    @_request "POST", path, body, callback

  _request: (method, path, body, callback) ->
    self = @

    host = "#{@options.team}.slack.com"
    headers =
      Host: host

    path += "?token=#{@options.token}"

    reqOptions =
      agent    : false
      hostname : host
      port     : 443
      path     : path
      method   : method
      headers  : headers

    if method is "POST"
      body = new Buffer body
      reqOptions.headers["Content-Type"] = "application/x-www-form-urlencoded"
      reqOptions.headers["Content-Length"] = body.length

    request = https.request reqOptions, (response) ->
      data = ""
      response.on "data", (chunk) ->
        data += chunk

      response.on "end", ->
        if response.statusCode >= 400
          self.logError "Slack services error: #{response.statusCode}"
          self.logError data

        #console.log "HTTPS response:", data
        callback? null, data

        response.on "error", (err) ->
          self.logError "HTTPS response error:", err
          callback? err, null

    if method is "POST"
      request.end body, "binary"
    else
      request.end()

    request.on "error", (err) ->
      self.logError "HTTPS request error:", err
      self.logError err.stack
      callback? err

  _escapeHtml: (string) ->
    string
      # Escape entities
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')

      # Linkify. We assume that the bot is well-behaved and
      # consistently sending links with the protocol part
      .replace(/((\bhttp)\S+)/g, '<$1>')

  _unescapeHtml: (string) ->
    string
      # Unescape entities
      .replace(/&amp;/g, '&')
      .replace(/&lt;/g, '<')
      .replace(/&gt;/g, '>')

      # Convert markup into plain url string.
      .replace(/<((\bhttps?)[^|]+)(\|(.*))+>/g, '$1')
      .replace(/<((\bhttps?)(.*))?>/g, '$1')

exports.use = (robot) ->
  new IrcBot robot

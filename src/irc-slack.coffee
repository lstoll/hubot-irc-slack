# Hubot dependencies
{Robot, Adapter, TextMessage, EnterMessage, LeaveMessage, Response} = require 'hubot'
https = require 'https'
querystring = require 'querystring'
FormData = require 'form-data'

# Custom Response class that adds a sendPrivate m
class IrcResponse extends Response
  sendPrivate: (strings...) ->
    @robot.adapter.sendPrivate @envelope, strings...

  paste: (strings...) ->
    @robot.adapter.paste @envelope, strings...

  upload: (filename, buf) ->
    @robot.adapter.upload @envelope, filename, buf

# Irc library
Irc = require 'irc'

Log = require('log')
logger = new Log process.env.HUBOT_LOG_LEVEL or 'info'

class IrcBot extends Adapter

  send: (envelope, strings...) ->
    logger.info "Starting send"
    destination = envelope.reply_to || envelope.room || envelope.user.reply_to

    if destination.match /^#/
      # it's a room, send over HTTP
      @sendRoom destination, strings...
    else
      # user, send over IRC because API limitation
      @sendPrivate destination, strings...

  sendRoom: (destination, strings...) ->
    strings.forEach (str) =>
      str = @_escapeHtml str
      data = querystring.stringify
        username   : @options.nick
        channel    : destination
        text       : str
        link_names : @options.link_names if @options?.link_names?

      console.log data

      @robot.http("https://#{@options.team}.slack.com/api/chat.postMessage?token=#{@options.token}")
        .header("Content-Type", "application/x-www-form-urlencoded")
        .post(data) (err, res, body) ->
          if err
            logger.err err
          else
            logger.debug body


  sendPrivate: (destination, strings...) ->
    for str in strings
      @bot.say destination, str

  reply: (envelope, strings...) ->
    for str in strings
      @send envelope, "#{envelope.user.name}: #{str}"

  paste: (envelope, strings...) ->
    destination = envelope.reply_to || envelope.room || envelope.user.reply_to
    @_channelId destination, (chanId) =>
      strings.forEach (str) =>
        data = querystring.stringify
          channels : chanId
          content  : str
          filetype : 'txt'

        console.log envelope

        @robot.http("https://#{@options.team}.slack.com/api/files.upload?token=#{@options.token}")
          .header("Content-Type", "application/x-www-form-urlencoded")
          .post(data) (err, res, body) ->
            if err
              logger.err err
            else
              logger.debug body

  upload: (envelope, filename, buf) ->
    destination = envelope.reply_to || envelope.room || envelope.user.reply_to
    @_channelId destination, (chanId) =>
      form = new FormData()
      form.append("token", @options.token)
      form.append("channels", chanId)
      form.append("file", buf, filename: filename)

      form.submit "https://#{@options.team}.slack.com/api/files.upload", (err, res) ->
        logger.err err if err
        res.resume()

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
      whitelistRooms: process.env.HUBOT_IRC_WHITELIST_ROOMS
      blacklistRooms: process.env.HUBOT_IRC_BLACKLIST_ROOMS or ''

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

      # If we don't have a from, or the from is us - drop the input
      if !from || from.toLowerCase().match ///^#{options.nick.toLowerCase}///
        logger.debug "Ignoring message from #{from}, because I think it's coming from me"
        return

      logger.debug "From #{from} to #{to}: #{message}"

      # Don't say anything if we're blacklisted
      if to in options.blacklistRooms.split ','
        return

      # If there's a whitelist, don't say anything unless we're whitelisted
      if options.whitelistRooms && !(to in options.whitelistRooms.split ',')
        return

      user = self.createUser to, from
      if user.room
        logger.info "#{to} <#{from}> #{message}"
      else
        unless message.indexOf(to) == 0
          message = "#{to}: #{message}"
        logger.debug "msg <#{from}> #{message}"

      # Slack likes to reformat email addresses, string that out.
      message = message.replace /mailto:[^\s@]*@[^\s@]*\|([^\s@]*@[^\s@]*)/, (match, p1) -> p1

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

  _channelId: (name, cb) ->
    @robot.http("https://#{@options.team}.slack.com/api/channels.list?token=#{@options.token}")
      .get() (err, res, body) ->
        if err
          logger.err err
        else
          chans = JSON.parse(body)
          channel = (item for item in chans.channels when item.name == name.replace("#", ""))
          cb(channel[0].id)



exports.use = (robot) ->
  new IrcBot robot

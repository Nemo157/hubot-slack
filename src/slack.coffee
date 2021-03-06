{Robot, Adapter, TextMessage, TextListener} = require 'hubot'
https = require 'https'

class Slack extends Adapter
  constructor: (robot) ->
    super robot
    @alwaysListeners = []

  channelMapping: (channel_name, channel_id) ->
    channel_mapping = @robot.brain.get("slack-channel-mapping") ? {}
    if channel_id? 
      if channel_mapping[channel_name] != channel_id
        channel_mapping[channel_name] = channel_id
        @robot.brain.set("slack-channel-mapping", channel_mapping)
    else
      return channel_mapping[channel_name] ? @robot.brain.get("slack-channel-mapping-#{channel_name}")


  ###################################################################
  # Slightly abstract logging, primarily so that it can
  # be easily altered for unit tests.
  ###################################################################
  log: console.log.bind console
  logError: console.error.bind console


  ###################################################################
  # Communicating back to the chat rooms. These are exposed
  # as methods on the argument passed to callbacks from
  # robot.respond, robot.listen, etc.
  ###################################################################
  send: (envelope, strings...) ->
    channel = envelope.reply_to || @channelMapping(envelope.room) || envelope.room
    @log "Sending message to #{channel}"

    strings.forEach (str) =>
      str = @escapeHtml str
      args = {
        username   : envelope.slack?.overrides?.username ? @robot.name
        channel    : channel
        text       : str
        link_names : @options.link_names if @options?.link_names?
      }

      if envelope.slack?.overrides?.icon_url?
        args.icon_url = envelope.slack.overrides.icon_url

      if envelope.slack?.overrides?.icon_emoji?
        args.icon_emoji = envelope.slack.overrides.icon_emoji

      @post "/services/hooks/hubot", JSON.stringify args

  reply: (envelope, strings...) ->
    @log "Sending reply"

    user_name = envelope.user?.name || envelope?.name

    strings.forEach (str) =>
      @send envelope, "#{user_name}: #{str}"

  topic: (params, strings...) ->
    # TODO: Set the topic


  custom: (message, data)->
    @log "Sending custom message"

    channel = message.reply_to || @channelMapping(message.room) || message.room

    attachment =
      text     : @escapeHtml data.text
      fallback : @escapeHtml data.fallback
      pretext  : @escapeHtml data.pretext
      color    : data.color
      fields   : data.fields
    args = JSON.stringify
      username    : @robot.name
      channel     : channel
      attachments : [attachment]
      link_names  : @options.link_names if @options?.link_names?
    @post "/services/hooks/hubot", args
  ###################################################################
  # HTML helpers.
  ###################################################################
  escapeHtml: (string) ->
    string
      # Escape entities
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')

      # Linkify. We assume that the bot is well-behaved and
      # consistently sending links with the protocol part
      .replace(/((\bhttp)\S+)/g, '<$1>')

  unescapeHtml: (string) ->
    string
      # Unescape entities
      .replace(/&amp;/g, '&')
      .replace(/&lt;/g, '<')
      .replace(/&gt;/g, '>')

      # Convert markup into plain url string.
      .replace(/<((\bhttps?)[^|]+)(\|(.*))+>/g, '$1')
      .replace(/<((\bhttps?)(.*))?>/g, '$1')


  ###################################################################
  # Parsing inputs.
  ###################################################################
  channels: ->
    @robot.brain.get('slack-channels-whitelist') ? []

  parseOptions: ->
    @options =
      token : process.env.HUBOT_SLACK_TOKEN
      team  : process.env.HUBOT_SLACK_TEAM
      name  : process.env.HUBOT_SLACK_BOTNAME or 'slackbot'
      link_names: process.env.HUBOT_SLACK_LINK_NAMES or 0

  getMessageFromRequest: (req) ->
    # Parse the payload
    hubotMsg = req.param 'text'
    room = req.param 'channel_name'

    @unescapeHtml hubotMsg if hubotMsg

  getAuthorFromRequest: (req) ->
    # Return an author object
    id       : req.param 'user_id'
    name     : req.param 'user_name'

  userFromParams: (params) ->
    # hubot < 2.4.2: params = user
    # hubot >= 2.4.2: params = {user: user, ...}
    user = {}
    if params.user
      user = params.user
    else
      user = params

    if user.room and not user.reply_to
      user.reply_to = user.room

    user
  ###################################################################
  # The star.
  ###################################################################
  run: ->
    self = @
    @parseOptions()

    @log "Slack adapter options:", @options

    return @logError "No services token provided to Hubot" unless @options.token
    return @logError "No team provided to Hubot" unless @options.team

    @robot.on 'slack-attachment', (payload)=>
      @custom(payload.message, payload.content)

    # Listen to incoming webhooks from slack
    self.robot.router.post "/hubot/slack-webhook", (req, res) ->
      self.log "Incoming message received"

      hubotMsg = self.getMessageFromRequest req
      author = self.getAuthorFromRequest req
      author = self.robot.brain.userForId author.id, author
      author.reply_to = req.param 'channel_id'
      author.room = req.param 'channel_name'
      self.channelMapping(req.param('channel_name'), req.param('channel_id'))
      channels = self.channels()

      if hubotMsg and author
        if author.room in channels
          # Pass to the robot
          self.receive new TextMessage(author, hubotMsg)
        self.alwaysReceive new TextMessage(author, hubotMsg)

      # Just send back an empty reply, since our actual reply,
      # if any, will be async above
      res.end ""

    # Provide our name to Hubot
    self.robot.name = @options.name

    # Tell Hubot we're connected so it can load scripts
    @log "Successfully 'connected' as", self.robot.name
    self.emit "connected"

  alwaysReceive: (message) ->
    results = []
    for listener in @alwaysListeners
      try
        results.push listener.call(message)
        break if message.done
      catch error
        @robot.emit('error', error, new @robot.Response(@robot, message, []))

        false

  alwaysRespond: (regex, callback) ->
    re = regex.toString().split('/')
    re.shift()
    modifiers = re.pop()

    pattern = re.join('/')
    name = @robot.name.replace(/[-[\]{}()*+?.,\\^$|#\s]/g, '\\$&')

    if @robot.alias
      alias = @robot.alias.replace(/[-[\]{}()*+?.,\\^$|#\s]/g, '\\$&')
      newRegex = new RegExp(
        "^[@]?(?:#{alias}[:,]?|#{name}[:,]?)\\s*(?:#{pattern})"
        modifiers
      )
    else
      newRegex = new RegExp(
        "^[@]?#{name}[:,]?\\s*(?:#{pattern})",
        modifiers
      )

    @alwaysListeners.push new TextListener(@robot, newRegex, callback)

  whitelistChannel: (channel) ->
    channels = @channels()
    if channel not in channels
      channels.push(channel)
      robot.brain.set('slack-channels-whitelist', channels)

  blacklistChannel: (channel) ->
    channels = @channels()
    if channel in channels
      index = channels.indexOf(channel)
      channels[index..index] = []
      robot.brain.set('slack-channels-whitelist', channels)

  ###################################################################
  # Convenience HTTP Methods for sending data back to slack.
  ###################################################################
  get: (path, callback) ->
    @request "GET", path, null, callback

  post: (path, body, callback) ->
    @request "POST", path, body, callback

  request: (method, path, body, callback) ->
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


###################################################################
# Exports to handle actual usage and unit testing.
###################################################################
exports.use = (robot) ->
  new Slack robot

# Export class for unit tests
exports.Slack = Slack

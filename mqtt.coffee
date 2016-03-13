# Pimatic MQTT plugin
module.exports = (env) ->

  mqtt = require 'mqtt'
  Promise = env.require 'bluebird'

  deviceTypes = {}
  for device in [
    'mqtt-switch'
    'mqtt-dimmer'
    'mqtt-sensor'
    'mqtt-presence-sensor'
    'mqtt-contact-sensor'
    'mqtt-buttons'
  ]
    # convert kebap-case to camel-case notation with first character capitalized
    className = device.replace /(^[a-z])|(\-[a-z])/g, ($1) -> $1.toUpperCase().replace('-','')
    deviceTypes[className] = require('./devices/' + device)(env)

  # Pimatic MQTT Plugin class
  class MqttPlugin extends env.plugins.Plugin

    init: (app, @framework, @config) =>
  
      @connected = false

      options = (
        host: @config.host
        port: @config.port
        username: @config.username or false
        password: if @config.password then new Buffer(@config.password) else false
        keepalive: 180
        clientId: 'pimatic_' + Math.random().toString(16).substr(2, 8)
        reconnectPeriod: 5000
        connectTimeout: 30000
      )

      Connection = new Promise( (resolve, reject) =>
        @mqttclient = new mqtt.connect(options)
        @mqttclient.on("connect", () =>
          @connected = true
          env.logger.info "Successful connected to MQTT Broker"
          resolve()
        )
        @mqttclient.on('error', reject)
        return
      ).timeout(60000).catch( (error) ->
        env.logger.error "Error on connecting to MQTT Broker #{error.message}"
        env.logger.debug error.stack
        return
      )

      @mqttclient.on 'reconnect', () =>
        env.logger.info "Reconnecting to MQTT Broker"

      @mqttclient.on 'offline', () ->
        @connected = false
        env.logger.info "MQTT Broker is offline"

      @mqttclient.on 'error', (error) ->
        @connected = false
        env.logger.error "connection error: #{error}"
        env.logger.debug error.stack

      @mqttclient.on 'close', () ->
        @connected = false
        env.logger.debug "Connection with MQTT Broker was closed"  

      # register devices
      deviceConfigDef = require("./device-config-schema")

      for className, classType of deviceTypes
        env.logger.debug "Registering device class #{className}"
        @framework.deviceManager.registerDeviceClass(className, {
          configDef: deviceConfigDef[className],
          createCallback: @callbackHandler(className, classType)
        })

      @framework.ruleManager.addActionProvider(new MqttActionProvider(@framework, @mqttclient))

      @framework.on "after init", =>
        # Check if the mobile-frontend was loaded and get a instance
        mobileFrontend = @framework.pluginManager.getPlugin 'mobile-frontend'
        if mobileFrontend?
          mobileFrontend.registerAssetFile 'js', 'pimatic-led-light/ui/led-light.coffee'
          mobileFrontend.registerAssetFile 'css', 'pimatic-led-light/ui/led-light.css'
          mobileFrontend.registerAssetFile 'html', 'pimatic-led-light/ui/led-light.html'
          mobileFrontend.registerAssetFile 'js', 'pimatic-led-light/ui/vendor/async.js'
          mobileFrontend.registerAssetFile 'js', 'pimatic-led-light/ui/vendor/one_color_2.5.0.js'
        else
          env.logger.warn 'your plugin could not find the mobile-frontend. No gui will be available'

    callbackHandler: (className, classType) ->
      # this closure is required to keep the className and classType context as part of the iteration
      return (config, lastState) =>
        return new classType(config, @, lastState)


  # action provider for publishing mqtt messages
  class MqttActionProvider extends env.actions.ActionProvider

    constructor: (@framework, @mqttclient) ->

    parseAction: (input, context) ->
      stringMessage = null
      stringTopic = null
      match = null
      fullMatch = no

      setMessageString = (m, tokens) => stringMessage = tokens
      setTopicString = (m, tokens) => stringTopic = tokens

      m = env.matcher(input, context)
        .match("publish mqtt message ")
        .matchStringWithVars(setMessageString)
        .match(" on topic ")
        .matchStringWithVars(setTopicString)

      if m.hadMatch()
        match = m.getFullMatch()
        return {
          token: match
          nextInput: input.substring(match.length)
          actionHandler: new MqttActionHandler(@framework, @mqttclient, stringTopic, stringMessage)
        }
      else
        return null

  class MqttActionHandler extends env.actions.ActionHandler

    constructor: (@framework, @mqttclient, @stringTopic, @stringMessage) ->

    executeAction: (simulate) ->
      @framework.variableManager.evaluateStringExpression(@stringTopic).then( (strTopic) =>
        @framework.variableManager.evaluateStringExpression(@stringMessage).then( (strMessage) =>
          if simulate
            return Promise.resolve("publish mqtt message " + strMessage + " on topic " + strTopic)
          else
            #env.logger.info "publish mqtt message " + strMessage + " on topic " + strTopic
            @mqttclient.publish(strTopic, strMessage)
            return Promise.resolve("publish mqtt message " + strMessage + " on topic " + strTopic)
        )
      )

  # ###Finally
  # Create a instance of my plugin
  # and return it to the framework.
  return new MqttPlugin
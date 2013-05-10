log = require('custom-logger')
cp = require('child_process')
fs = require('fs');
EventEmitter = require('eventemitter2').EventEmitter2
File = require('oofile').File
uuid = require('node-uuid').v4
config = require('./config')
request = require 'request'

module.exports = class Project extends EventEmitter

  server: true
  status: "stopped"

  constructor: (options) ->
    @id = uuid()
    @name = options.name
    @path = config.projects.path(@name)
    @favicon = @findFavicon()
    @log = new File "#{config.projects.logs}/#{@name}.log"
    process.on 'SIGINT', @destroy

  findFavicon: ->
    favicon = @path.find('**/favicon.*')[0]
    if favicon?
      return favicon.toString()
    else
      return config.web.path "public/images/default-favicon.png"

  start: (options) ->
    if @status is "started" or @status is "starting"
      @emit "warning", message: "Already running!"
    else
      # begin startup
      @emit "starting"
      @status = "starting"

      # if the project doesn't have a start command, destroy this project
      # and return false
      @package = @path('package.json')
      if not @package.exists()
        log.warn "#{@name} does not exist, skipping ..."
        @destroy()
        @server = false
        return false

      if @package.contents()?.port?
        options.port = @package.contents().port

      log.info "[#{@name}] starting on #{options.port} ..."

      # the project has a package, so start it up
      if @package.contents()?.scripts?.start?
        # get the start command and the process environment
        command = @package.contents().scripts.start.split ' '
      else
        log.warn "#{@name} does not define script.start, using 'node .' instead ..."
        command = ["node", "."]

      env = @getEnv port: options.port
      
      if @package.contents()?.workingDir?
        workingDir = @package.contents()?.workingDir
      else
        workingDir = @path.toString()

      # spawn the process
      @process = cp.spawn command.shift(), command,
        cwd: workingDir
        env: env

      # pipe data events
      @process.stdout.on 'data', (d) =>
        @emit 'log', message: d.toString()
        fs.appendFile @log.toString(), d
      @process.stderr.on 'data', (d) =>
        @emit 'log', message: d.toString(), type: 'err'
        fs.appendFile @log.toString(), d

      # on exit, update status and pipe the event
      @process.on 'exit', (code, signal) =>
        @status = "stopped"
        log.info "[#{@name}] stopped"
        @emit 'stopped', code: code

      checkStart = (counter=0) =>
        if counter >= 10
          @status = "unknown"
          @emit 'unknown'
          log.info "[#{@name}] unknown"
          return
        if @status is "starting"
          @isResponding (responding)=>
            if @status is "starting"
              if !responding
                clearTimeout(@checkTimer)
                @checkTimer = setTimeout =>
                  checkStart counter + 1
                , 500
              else
                @status = "started"
                @emit 'started'
                log.info "[#{@name}] started"

      checkStart()
      return true

  # shut down the server
  stop: =>
    @emit 'stopping'
    log.info "[#{@name}] stopping ..."
    @process.kill()

  # restart the server
  restart: =>
    @emit 'restarting'
    log.info "[#{@name}] restarting ..."
    if @status is "started" or @status is "starting"
      @process.on 'exit', => @start port: @port
      @stop()
    else
      @start port: @port

  # shut down the server and clean up event listeners to destroy
  # the reference to this project
  destroy: =>
    if @process?
      @stop()
      @removeListener 'stopped', @_cleanUp
      @on 'stopped', @_cleanUp
    else
      @_cleanUp()

  # Once we've confirmed that all the async process management
  # is ready for a destroy, do the bookkeeping
  _cleanUp: =>
    @status = "dead"
    process.removeListener 'SIGINT', @destroy

  # merge the current process env to the child process, plus any additional
  # options; also, update the port property
  getEnv: (options) ->
    @port = options.port if options.port?
    env = {}
    env[key] = value for key, value of process.env
    env[key.toUpperCase()] = value for key, value of options
    return env

  isResponding: (cb)=>
    timer = setTimeout ()->
      cb(false)
    , 1000
    request "http://localhost:#{@port}", (err, response, body)=>
      if !err?
        clearTimeout timer
        cb(true)
      else
        if err?.code isnt "ECONNREFUSED"
          cb(true)
        else
          cb(false)


  tail: (cb) ->
    cp.exec "tail -n 100 #{@log}", (err, stdout, stderr) ->
      cb stdout

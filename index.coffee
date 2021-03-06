
# A fluent DSL for scraping web content using [PhantomJS](http://phantomjs.org/) 
# and the [PhantomJS bridge for Node](https://github.com/sgentle/phantomjs-node).
#

# We require EventEmitter to be inherited by Request
Emitter = require('events').EventEmitter

# Duration to make time outs friendlier
Duration = require('duration-js')


# A helper to provide the current time
now = ->
    (new Date).getTime()

# The module exports are defined in this function to make it easy to inject a 
# mock for unit testing.
binder = (phantom) ->

    # Use the real PhantomJS bridge if an alternative is not injected
    phantom = if typeof phantom == 'object' then phantom else require 'phantom'

    # Connection strategies
    class PhantomStrategy
        port: 12340
        supportsAutoClose: false
        open: (callback) ->  # phantom.create((ph) -> )
        exit: ->

    class NewPhantomStrategy extends PhantomStrategy
        phantom: null
        supportsAutoClose: true
        open: (callback) ->
            phantom.create {port: @port}, (ph) =>
                @phantom = ph
                callback ph
        exit: ->
            @phantom.exit()


    class NewPortPhantomStrategy extends PhantomStrategy
        phantom: null
        supportsAutoClose: true
        open: (callback) ->
            phantom.create {port: @port++}, (ph) =>
                @phantom = ph
                callback ph
        exit: ->
            @phantom.exit()
    
    class RecycledPhantomStrategy extends PhantomStrategy
        phantom: null
        open: (callback) ->
            if not @phantom?
                phantom.create (ph) =>
                    ph.set('onError', =>
                        ph.exit(1)
                        @phantom = null
                    )
                    @phantom = ph
                    callback ph
            else
                callback @phantom

        exit: ->
            @phantom.exit()

    class PooledPhantomStrategy extends PhantomStrategy
        constructor: (@size = 4, @queueDepth = 4) ->
            @pool = []
            @busy = []
            @created = 0  # Number of connections created; used to keep ports unique
            @queue = []
            @timer = []
            @timeout = 5000 # ms to wait before releasing and recreating a connection
            @interval = null

            for i in [0...@size]
                @busy[i] = false
                @timer[i] = null
                @queue[i] = []

            tick = =>
                for index, begin in @timer
                    if begin isnt null
                        if now() - begin > @timeout
                            @busy[index] = false
                            @timer[index] = null
                            @pool[index] = null
                            @create index

            @interval = setInterval tick, Math.floor(@timeout / 4)

        fill: (upto = @size) ->
            for index in [0...upto]
                @create index

        create: (index) ->
            if index < @size and typeof @pool[index] isnt 'object' and !@busy[index]
                @busy[index] = true
                phantom.create {port: @port + @created++}, (ph) =>
                    @pool[index] = ph
                    @busy[index] = false
                    ph.set('onError', =>
                        if typeof @pool[index] is 'object' and @pool[index]['exit']? then @pool[index].exit()
                        console.error "A Phantom worker crashed. Removing from the pool."
                        @pool[index] = null
                    )
                    @ready(index)

        ready: (index) ->
            if @queue[index].length > 0
                callback = @queue[index].shift()
                @exec(index, callback)
        
        finished: (index) ->
            @timer[index] = null
            @busy[index] = false
            @ready(index)

        exit: ->
            for idx in [0...@size]
                if typeof @pool[idx] is 'object'
                    @pool[idx].exit()

        exec: (index, callback) ->
            if @busy[index] or !@pool[index]?
                if @queue[index].length < @queueDepth - 1
                    @queue[index].push callback
                else
                    pos = 0
                    min = Infinity
                    for idx in [0...@size]
                        min = Math.min min, @queue[pos].length

                    if min >= @queueDepth
                        throw new Error("Easy trigger, you're issuing too many requests. These things take time!")
                    else
                        @queue[pos].push callback

                if (!@pool[index]) then @create index

            else
                @busy[index] = true
                @timer[index] = now()
                done = =>
                    @finished(index)

                callback(@pool[index], done)


        getIndex: -> 0 # Implement this in child classes!
            
        open: (callback) ->
            index = @getIndex()
            @create index
            @exec index, callback



    class RoundRobinPhantomStrategy extends PooledPhantomStrategy
        constructor: (size, min, queueDepth) ->
            super(size, queueDepth)
            @cursor = 0

            if min?
                @fill(min)
       
        getIndex: ->
            if @cursor >= @size
                @cursor = 0
            @cursor++

                
    class RandomPhantomStrategy extends PooledPhantomStrategy
        getIndex: -> Math.floor Math.random() * @size

    connection = new NewPhantomStrategy()

    # Events that may be emitted by a Request
    events =
        HALT: 'halted'
        PHANTOM_CREATE: 'phantom-created'
        PAGE_CREATE: 'page-created'
        PAGE_OPEN: 'page-opened'
        TIMEOUT: 'timeout'
        REQUEST_FAILURE: 'failed'
        READY: 'ready'
        FINISH: 'finished'
        CHECKING: 'checking'
        CONSOLE: 'console'
    
    # Default values for the request builder
    builders =
        when:
            css: 'when-css'
            function: 'when-func'
            none: 'when-none'
        action:
            css: 'action-css'
            parts: 'action-parts'
            evaluate: 'action-evaluate'
            function: 'action-function'


    # Allowable DOM node properties
    nodeProperties = ['attributes', 'baseURI', 'childElementCount', 'childNodes'
        ,'classList', 'className', 'dataset', 'dir', 'hidden', 'id', 'innerHTML'
        ,'innerText', 'lang', 'localName', 'namespaceURI', 'nodeName', 'nodeType'
        ,'nodeValue', 'outerHTML', 'outerText', 'prefix', 'style', 'tabIndex'
        ,'tagName', 'textContent', 'title', 'type', 'value', 'children', 'href'
        ,'src'
    ]

    # A fluent builder
    class Builder
        constructor: ->
            @_build =
                when: builders.when.none
                action: builders.action.function
            
            @_props = 
                condition:
                    callback: null
                    argument: null
                action: -> console.log "No default action provided"
                scraper:
                    extractor: null
                    handler: null
                    argument: null
                    properties: ['children', 'tagName', 'innerText', 'innerHTML', 'id', 'attributes', 'href', 'src', 'className']
                    query: null
                timeout:
                    duration: 3000
                    handler: -> console.error "Timeout"
                url: null


        # Set a timeout duration
        until: (timeout) -> @for timeout
        timeout: (timeout) -> @for timeout
        for: (timeout) ->
            if typeof timeout is 'number'
                @_props.timeout.duration = timeout
            else if typeof timeout is 'string'
                @_props.timeout.duration = Duration.parse(timeout).milliseconds()
            else if typeof timeout is 'object' and timeout instanceof Duration
                @_props.timeout.duration = Duration.milliseconds()
            else
                throw Error "Expected timeout to be a number"
            @

        # Never timeout
        forever: -> @for 0

        # Timeout after one tick
        immediately: -> @for 100

        otherwise: (callback) ->
            if typeof callback isnt 'function' then throw Error "Expected timeout handler to be a function"
            @_props.timeout.handler = callback
            @

        # Set the URL
        url: (url) -> @from url
        from: (url) ->
            if typeof url isnt 'string' then throw Error "Expected URL to be a string"
            @_props.url = url
            @

        # Create an action to be run using Phantom's `page.evaluate`
        evaluate: (scraper, handler, argument) ->
            if typeof scraper isnt 'function' then throw Error "Expected scraping function"
            if typeof handler isnt 'function' then throw Error "Expected handler function"
            
            @_build.action = builders.action.evaluate

            @_props.action = (page) -> page.evaluate scraper, handler, argument
            @


        # Run a generic action that receives a Phantom page object as its only argument.
        invoke: (callback) -> @run(callback)
        run: (callback) ->
            if typeof callback isnt 'function' then throw Error "Expected action to be a function"
            @_build.action = builders.action.function
            @_props.action = callback
            @

        # Assign a condition that must be satisfied before scraping content
        when: (condition, argument) ->
            if typeof condition is 'string' then condition = [condition]

            if typeof condition is 'object'
                @_build.when = builders.when.css

                minimum = if typeof argument is 'number' then argument else 1
                @_props.condition = 
                    callback: (args) ->
                        result = true
                        for k, query of args.queries
                            if (document.querySelectorAll(query).length < args.minimum) then result = false
                        result

                    argument:
                        minimum: minimum
                        queries: condition

            else if typeof condition is 'function'
                @_build.when = builders.when.function

                @_props.condition =
                    callback: condition

                if typeof argument isnt 'undefined'
                    @_props.condition.argument = argument

            else
                throw Error "Invalid condition"

            @

        # Select content on the page by either a CSS selector or a function to run
        # in the context of the page with access to `window` and `document`.
        extract: (selector, argument) -> @select(selector, argument)
        select: (selector, argument) ->
            if typeof selector is 'string' or typeof selector is 'object'
                @_build.action = builders.action.css
                if typeof selector is 'string' then selector = [selector]
                @_props.scraper.query = selector
                @when selector, argument

            else if typeof selector is 'function'
                @_build.action = builders.action.parts
                @_props.scraper.extractor = selector

            else
                throw Error "Invalid selector"

            if typeof argument isnt 'undefined'
                @_props.scraper.argument = argument

            @

        # Describe how to handle scraped results
        process: (handler) -> @handle handler
        receive: (handler) -> @handle handler
        handle: (handler) ->
            @_props.scraper.handler = handler
            @

        properties: (props...) -> @members props
        members: (properties...) ->
            @_props.scraper.properties = []
            traverse = (props) =>
                if typeof props is 'object' and props instanceof Array and props.length > 0
                    for prop in props
                        if typeof prop is 'string'
                            if nodeProperties.indexOf(prop) < 0 then throw Error "Invalid property: #{prop}"
                            @_props.scraper.properties.push prop
                        else if typeof prop is 'object'
                            traverse prop
            traverse properties
            @

        # Terms that have no effect but lend a more fluent feel
        and: -> @
        then: -> @
        of: -> @
        with: -> @

        # Build a request object as described
        build: ->
            req = new Request
            
            # Assign the URL
            if typeof @_props.url is 'string' then req.url @_props.url
            
            # Handle timeouts and other errors
            if @_props.timeout.duration? and @_props.timeout.duration >= 0 then req.timeout @_props.timeout.duration
            req.on events.TIMEOUT, @_props.timeout.handler
            req.on events.REQUEST_FAILURE, @_props.timeout.handler

            # Build an appropriate sentry
            switch @_build.when
                # CSS selector is generated by when()
                when builders.when.function, builders.when.css
                    req.condition @_props.condition.callback, @_props.condition.argument
            
            # Build an action to invoke when ready
            switch @_build.action
                when builders.action.function, builders.action.evaluate
                    req.action @_props.action
                
                when builders.action.parts
                    extractor = @_props.scraper.extractor
                    handler = @_props.scraper.handler
                    argument = @_props.scraper.argument
                    if typeof argument is 'undefined' then argument = ''

                    req.action (page) ->
                        pg = page
                        withPageContext = (args...) ->
                            args.push pg
                            handler.apply(@, args)

                        page.evaluate extractor, withPageContext, argument

                when builders.action.css
                    args =
                        query: @_props.scraper.query
                        preserve: @_props.scraper.properties
                    
                    handler = @_props.scraper.handler

                    extractor = (args) ->
                        result = null

                        filter = (elems) ->
                            results = []
                            for elem in elems when elem.id?
                                obj = {}
                                for key in args.preserve
                                    if key is 'children' or key is 'childNodes'
                                        obj[key] = filter(elem[key])
                                    else
                                        obj[key] = elem[key]

                                results.push obj

                            results
                        
                        if (args.query.length is 1)
                            filter document.querySelectorAll(args.query[0])
                        else
                            results = if args.query instanceof Array then [] else {}

                            for key, query of args.query
                                results[key] = filter document.querySelectorAll(query)

                            results

                    req.action (page) ->
                        pg = page
                        withPageContext = (args...) ->
                            args.push pg
                            handler.apply(@, args)

                        page.evaluate extractor, withPageContext, args
                    

            req

        # Build and immediately execute a request
        execute: (url) ->
            if typeof url isnt 'undefined' then @from url
            req = @build()
            req.execute()
            req


    # A request
    class Request
        # Private method to clean up open Phantom instances and notify listeners
        end = ->
            @emit events.FINISH
            clearInterval @_interval

            if typeof @_onFinish is 'function'
                @_onFinish()

            if @_closeWhenFinished and connection.supportsAutoClose
                @_phantom.exit()

        log = (msg) ->
            console.log msg

        constructor: ->
            @_url = ''
            @_condition = null
            @_action = null
            @_interval = null
            @_phantom = null
            @_page = null
            @_onFinish = null
            @_timeout = 3000
            @_bindConsole = false
            @_debug = false
            @_closeWhenFinished = true

        # Add a callback that must return true before emitting ready
        condition: (callback, argument) ->
            if typeof callback isnt 'function' and typeof callback isnt 'object' then throw Error "Invalid condition"
            if typeof argument is 'undefined' then argument = null
            @_condition =
                callback: callback
                argument: argument
            this

        # Add an action to be performed whenc ontent is ready
        action: (callback) ->
            if typeof callback isnt 'function' then throw Error "Invalid action"
            @_action = callback
            this

        # Set or get the timeout value
        timeout: (value) ->
            if typeof value == 'number'
                @_timeout = value
                this
            else
                @_timeout

        # Automaticaly close Phantom when finished
        closeWhenFinished: (close) ->
            if typeof close is 'boolean'
                @_closeWhenFinished = close
            else
                @_closeWhenFinished

        # Toggle binding console.log to the PhantomJS instance's console.log.
        console: (bind) ->
            if typeof bind is 'boolean'
                @_bindConsole = bind
                if @_bindConsole
                    @addListener events.CONSOLE, log
                else
                    @removeListener events.CONSOLE, log
                @

            else
                @_bindConsole
            
        # Enable or disable debugging
        debug: (isOn) ->
            if typeof isOn is 'boolean'
                @_debug = isOn
                
                for key, event of events
                    do (event) ->
                        callback = -> console.log 'DEBUG: ' + event

                        if @_debug
                            @addListener event, callback
                        else
                            #@removeListener event, callback
                @

            else
                @_debug

        # Set or get the URL
        url: (url) ->
            if typeof url == 'string'
                @_url = url
                this
            else
                @_url

        # Interrupt execution and end ASAP
        halt: ->
            @emit events.HALT
            end.call this

        # Execute the request
        execute: (url) ->
            @url url   # Set the URL if it was provided

            connection.open (ph, doneWithConnection) =>
                @_onFinish = doneWithConnection

                ph.set('onError', => @emit events.REQUEST_FAILURE)

                @_phantom = ph
                @emit events.PHANTOM_CREATE
                
                ph.createPage (page) =>
                    @_page = page
                    page.set('onConsoleMessage', (msg) => @emit events.CONSOLE, msg)
                    page.set('onError', => @emit events.REQUEST_FAILURE)

                    @emit events.PAGE_CREATE
                    page.open @_url, (status) =>
                        if (status != 'success')        # Request failed
                            @emit events.REQUEST_FAILURE

                        else if @_condition isnt null    # Request succeeded, but we have to verify the DOM
                            start = now()
                            
                            # This function is called over and over until all conditions 
                            # have been satisfied or we run out of time.
                            tick = =>
                                @emit events.CHECKING

                                # Timeout
                                if @_timeout > 0 and now() - start > @_timeout
                                    @emit events.TIMEOUT
                                    end.call this

                                # Check sentry and perform action if ready
                                else
                                    handler = (result) =>
                                        if result
                                            @emit events.READY
                                            @_action(page)
                                            end.call this

                                    page.evaluate @_condition.callback, handler, @_condition.argument


                            if @_timeout >= 0
                                @_interval = setInterval tick, 250
                            tick()

                        else                            # Request succeeded and no verifications necessary - proceed!
                            @emit events.READY
                            @_action(page)
                            end.call this

    # Ensure that Request can emit events
    Request.prototype.__proto__ = Emitter.prototype

    # Export bound classes
    exports =
        "Request": Request
        "Builder": Builder
        "create": -> new Builder
        "events": events
        "recycle": (val) ->
            if val then connection = new RecycledPhantomStrategy
            else connection = new NewPhantomStrategy
        
        "ConnectionStrategy":    # Deprecated
            RoundRobin: RoundRobinPhantomStrategy
            New: NewPhantomStrategy
            NewPort: NewPortPhantomStrategy
            Recycled: RecycledPhantomStrategy
            Random: RandomPhantomStrategy
        setConnectionStrategy: (strategy) -> # Deprecated
            if strategy instanceof PhantomStrategy
                connection = strategy
            else
                throw Error "Invalid connection strategy"

        "RoundRobin": RoundRobinPhantomStrategy
        "RandomPool": RandomPhantomStrategy
        "NewPhantom": NewPhantomStrategy
        "NewPhantomAndPort": NewPortPhantomStrategy
        "RecycledPhantom": RecycledPhantomStrategy
        "connections": -> connection
        "connectWith": (strategy) ->
            if strategy instanceof PhantomStrategy
                connection = strategy
            else
                throw Error "Invalid connection strategy"
        

module.exports = binder()
module.exports.inject = binder

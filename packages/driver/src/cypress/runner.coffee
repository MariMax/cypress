_ = require("lodash")
moment = require("moment")
Promise = require("bluebird")

$Log = require("./log")
$utils = require("./utils")

defaultGrepRe   = /.*/
mochaCtxKeysRe  = /^(_runnable|test)$/
betweenQuotesRe = /\"(.+?)\"/

HOOKS = "beforeAll beforeEach afterEach afterAll".split(" ")
TEST_BEFORE_RUN_EVENT = "runner:test:before:run"
TEST_AFTER_RUN_EVENT = "runner:test:after:run"

ERROR_PROPS      = "message type name stack fileName lineNumber columnNumber host uncaught actual expected showDiff".split(" ")
RUNNABLE_LOGS    = "routes agents commands".split(" ")
RUNNABLE_PROPS   = "id title root hookName err duration state failedFromHook body".split(" ")

# ## initial payload
# {
#   suites: [
#     {id: "r1"}, {id: "r4", suiteId: "r1"}
#   ]
#   tests: [
#     {id: "r2", title: "foo", suiteId: "r1"}
#   ]
# }

# ## normalized
# {
#   {
#     root: true
#     suites: []
#     tests: []
#   }
# }

# ## resetting state (get back from server)
# {
#   scrollTop: 100
#   tests: {
#     r2: {id: "r2", title: "foo", suiteId: "r1", state: "passed", err: "", routes: [
#         {}, {}
#       ]
#       agents: [
#       ]
#       commands: [
#         {}, {}, {}
#       ]
#     }}
#
#     r3: {id: "r3", title: "bar", suiteId: "r1", state: "failed", logs: {
#       routes: [
#         {}, {}
#       ]
#       spies: [
#       ]
#       commands: [
#         {}, {}, {}
#       ]
#     }}
#   ]
# }

fire = (event, runnable, Cypress) ->
  runnable._fired ?= {}
  runnable._fired[event] = true

  ## dont fire anything again if we are skipped
  return if runnable._ALREADY_RAN

  Cypress.action(event, wrap(runnable), runnable)

fired = (event, runnable) ->
  !!(runnable._fired and runnable._fired[event])

testBeforeRunAsync = (test, Cypress) ->
  Promise.try ->
    if not fired("runner:test:before:run:async", test)
      fire("runner:test:before:run:async", test, Cypress)

runnableAfterRunAsync = (runnable, Cypress) ->
  Promise.try ->
    if not fired("runner:runnable:after:run:async", runnable)
      fire("runner:runnable:after:run:async", runnable, Cypress)

testAfterRun = (test, Cypress) ->
  if not fired(TEST_AFTER_RUN_EVENT, test)
    fire(TEST_AFTER_RUN_EVENT, test, Cypress)

    ## perf loop only through
    ## a tests OWN properties and not
    ## inherited properties from its shared ctx
    for own key, value of test.ctx
      if _.isObject(value) and not mochaCtxKeysRe.test(key)
        ## nuke any object properties that come from
        ## cy.as() aliases or anything set from 'this'
        ## so we aggressively perform GC and prevent obj
        ## ref's from building up
        test.ctx[key] = undefined

    ## reset the fn to be empty function
    ## for GC to be aggressive and prevent
    ## closures from hold references
    test.fn = ->

    ## prevent loop comprehension
    return null

reduceProps = (obj, props) ->
  _.reduce props, (memo, prop) ->
    if _.has(obj, prop) or obj[prop]
      memo[prop] = obj[prop]
    memo
  , {}

wrap = (runnable) ->
  ## we need to optimize wrap by converting
  ## tests to an id-based object which prevents
  ## us from recursively iterating through every
  ## parent since we could just return the found test
  reduceProps(runnable, RUNNABLE_PROPS)

wrapAll = (runnable) ->
  _.extend(
    {},
    reduceProps(runnable, RUNNABLE_PROPS),
    reduceProps(runnable, RUNNABLE_LOGS)
  )

wrapErr = (err) ->
  reduceProps(err, ERROR_PROPS)

getHookName = (hook) ->
  ## find the name of the hook by parsing its
  ## title and pulling out whats between the quotes
  name = hook.title.match(betweenQuotesRe)
  name and name[1]

forceGc = (obj) ->
  ## aggressively forces GC by purging
  ## references to ctx, and removes callback
  ## functions for closures
  for own key, value of obj.ctx
    obj.ctx[key] = undefined

  if obj.fn
    obj.fn = ->

anyTestInSuite = (suite, fn) ->
  for test in suite.tests
    return true if fn(test) is true

  for suite in suite.suites
    return true if anyTestInSuite(suite, fn) is true

  ## else return false
  return false

eachHookInSuite = (suite, fn) ->
  for type in HOOKS
    for hook in suite["_" + type]
      fn(hook)

  ## prevent loop comprehension
  return null

onFirstTest = (suite, fn) ->
  for test in suite.tests
    return test if fn(test)

  for suite in suite.suites
    return test if test = onFirstTest(suite, fn)

getAllSiblingTests = (suite, getTestById) ->
  tests = []
  suite.eachTest (test) =>
    ## iterate through each of our suites tests.
    ## this will iterate through all nested tests
    ## as well.  and then we add it only if its
    ## in our grepp'd _this.tests array
    if getTestById(test.id)
      tests.push test

  tests

getTestFromHook = (hook, suite, getTestById) ->
  ## if theres already a currentTest use that
  return test if test = hook?.ctx.currentTest

  ## if we have a hook id then attempt
  ## to find the test by its id
  if hook?.id
    found = onFirstTest suite, (test) =>
      hook.id is test.id

    return found if found

  ## returns us the very first test
  ## which is in our grepped tests array
  ## based on walking down the current suite
  ## iterating through each test until it matches
  found = onFirstTest suite, (test) =>
    getTestById(test.id)

  return found if found

  ## have one last final fallback where
  ## we just return true on the very first
  ## test (used in testing)
  onFirstTest suite, (test) -> true

## we have to see if this is the last suite amongst
## its siblings.  but first we have to filter out
## suites which dont have a grep'd test in them
isLastSuite = (suite, tests) ->
  return false if suite.root

  ## grab all of the suites from our grep'd tests
  ## including all of their ancestor suites!
  suites = _.reduce tests, (memo, test) ->
    while parent = test.parent
      memo.push(parent)
      test = parent
    memo
  , []

  ## intersect them with our parent suites and see if the last one is us
  _
  .chain(suites)
  .uniq()
  .intersection(suite.parent.suites)
  .last()
  .value() is suite

overrideRunnerHook = (Cypress, _runner, getTestById, getTest, setTest, getTests) ->
  ## bail if our _runner doesnt have a hook.
  ## useful in tests
  return if not _runner.hook

  ## monkey patch the hook event so we can wrap
  ## 'test:after:run' around all of
  ## the hooks surrounding a test runnable
  _this = @

  _runnerHook = _runner.hook

  _runner.hook = (name, fn) ->
    hooks = @suite["_" + name]

    ctx = @

    allTests = _this.tests

    changeFnToRunAfterHooks = ->
      originalFn = fn

      test = getTest()

      setTest(null)

      ## reset fn to invoke the hooks
      ## first but before calling next(err)
      ## we fire our events
      fn = ->
        testAfterRun(test, Cypress)

        ## and now invoke next(err)
        originalFn.apply(null, arguments)

    switch name
      when "afterEach"
        ## find all of the grep'd _this tests which share
        ## the same parent suite as our current _this test
        tests = getAllSiblingTests(getTest().parent, getTestById)

        ## make sure this test isnt the last test overall but also
        ## isnt the last test in our grep'd parent suite's tests array
        if @suite.root and (getTest() isnt _.last(getTests())) and (getTest() isnt _.last(tests))
          changeFnToRunAfterHooks()

      when "afterAll"
        ## find all of the grep'd _this tests which share
        ## the same parent suite as our current _this test
        if getTest()
          tests = getAllSiblingTests(getTest().parent, getTestById)

          ## if we're the very last test in the entire _this.tests
          ## we wait until the root suite fires
          ## else we wait until the very last possible moment by waiting
          ## until the root suite is the parent of the current suite
          ## since that will bubble up IF we're the last nested suite
          ## else if we arent the last nested suite we fire if we're
          ## the last test
          if (@suite.root and getTest() is _.last(getTests())) or
            (@suite.parent?.root and getTest() is _.last(tests)) or
              (not isLastSuite(@suite, allTests) and getTest() is _.last(tests))
            changeFnToRunAfterHooks()

    _runnerHook.call(@, name, fn)

matchesGrep = (runnable, grep) ->
  ## we have optimized this iteration to the maximum.
  ## we memoize the existential matchesGrep property
  ## so we dont regex again needlessly when going
  ## through tests which have already been set earlier
  if (not runnable.matchesGrep?) or (not _.isEqual(runnable.grepRe, grep))
    runnable.grepRe      = grep
    runnable.matchesGrep = grep.test(runnable.fullTitle())

  runnable.matchesGrep

getTestResults = (tests) ->
  _.map tests, (test) ->
    obj = _.pick(test, "id", "duration", "state")
    obj.title = test.originalTitle
    ## TODO FIX THIS!
    if not obj.state
      obj.state = "skipped"
    obj

normalizeAll = (suite, initialTests = {}, grep, setTestsById, setTests, onRunnable, onLogsById, getId) ->
  hasTests = false

  ## only loop until we find the first test
  onFirstTest suite, (test) ->
    hasTests = true

  ## if we dont have any tests then bail
  return if not hasTests

  ## we are doing a super perf loop here where
  ## we hand back a normalized object but also
  ## create optimized lookups for the tests without
  ## traversing through it multiple times
  tests         = {}
  grepIsDefault = _.isEqual(grep, defaultGrepRe)

  obj = normalize(suite, tests, initialTests, grep, grepIsDefault, onRunnable, onLogsById, getId)

  if setTestsById
    ## use callback here to hand back
    ## the optimized tests
    setTestsById(tests)

  if setTests
    ## same pattern here
    setTests(_.values(tests))

  return obj

normalize = (runnable, tests, initialTests, grep, grepIsDefault, onRunnable, onLogsById, getId) ->
  normalizer = (runnable) =>
    runnable.id = getId()

    ## tests have a type of 'test' whereas suites do not have a type property
    runnable.type ?= "suite"

    if onRunnable
      onRunnable(runnable)

    ## if we have a runnable in the initial state
    ## then merge in existing properties into the runnable
    if i = initialTests[runnable.id]
      _.each RUNNABLE_LOGS, (type) =>
        _.each i[type], onLogsById

      _.extend(runnable, i)

    ## reduce this runnable down to its props
    ## and collections
    return wrapAll(runnable)

  push = (test) =>
    tests[test.id] ?= test

  obj = normalizer(runnable)

  ## if we have a default grep then avoid
  ## grepping altogether and just push
  ## tests into the array of tests
  if grepIsDefault
    if runnable.type is "test"
      push(runnable)

    ## and recursively iterate and normalize all other _runnables
    _.each {tests: runnable.tests, suites: runnable.suites}, (_runnables, key) =>
      if runnable[key]
        obj[key] = _.map _runnables, (runnable) =>
          normalize(runnable, tests, initialTests, grep, grepIsDefault, onRunnable, onLogsById, getId)
  else
    ## iterate through all tests and only push them in
    ## if they match the current grep
    obj.tests = _.reduce runnable.tests ? [], (memo, test) =>
      ## only push in the test if it matches
      ## our grep
      if matchesGrep(test, grep)
        memo.push(normalizer(test))
        push(test)
      memo
    , []

    ## and go through the suites
    obj.suites = _.reduce runnable.suites ? [], (memo, suite) =>
      ## but only add them if a single nested test
      ## actually matches the grep
      any = anyTestInSuite suite, (test) =>
        matchesGrep(test, grep)

      if any
        memo.push(
          normalize(
            suite,
            tests,
            initialTests,
            grep,
            grepIsDefault,
            onRunnable,
            onLogsById,
            getId
          )
        )

      memo
    , []

  return obj

afterEachFailed = (Cypress, test, err) ->
  test.state = "failed"
  test.err = wrapErr(err)

  Cypress.action("runner:test:end", wrap(test))

hookFailed = (hook, err, hookName, getTestById, setTest) ->
  ## finds the test by returning the first test from
  ## the parent or looping through the suites until
  ## it finds the first test
  test = getTestFromHook(hook, hook.parent, getTestById)
  test.err = err
  test.state = "failed"
  test.duration = hook.duration
  test.hookName = hookName
  test.failedFromHook = true

  ## make sure we set this test as the current
  ## else its possible that our TEST_AFTER_RUN_EVENT
  ## will never fire if this failed in a before hook
  setTest(test)

  if hook.alreadyEmittedMocha
    ## TODO: won't this always hit right here???
    ## when would the hook not be emitted at this point?
    test.alreadyEmittedMocha = true
  else
    Cypress.action("runner:test:end", wrap(test))

_runnerListeners = (_runner, Cypress, _emissions, getTestById, setTest) ->
  _runner.on "start", ->
    Cypress.action("runner:start")

  _runner.on "end", ->
    Cypress.action("runner:end")

  _runner.on "suite", (suite) ->
    return if _emissions.started[suite.id]

    _emissions.started[suite.id] = true

    Cypress.action("runner:suite:start", wrap(suite))

  _runner.on "suite end", (suite) ->
    ## cleanup our suite + its hooks
    forceGc(suite)
    eachHookInSuite(suite, forceGc)

    return if _emissions.ended[suite.id]

    _emissions.ended[suite.id] = true

    Cypress.action("runner:suite:end", wrap(suite))

  _runner.on "hook", (hook) ->
    hookName = getHookName(hook)

    ## mocha incorrectly sets currentTest on before all's.
    ## if there is a nested suite with a before, then
    ## currentTest will refer to the previous test run
    ## and not our current
    if hookName is "before all" and hook.ctx.currentTest
      delete hook.ctx.currentTest

    ## set the hook's id from the test because
    ## hooks do not have their own id, their
    ## commands need to grouped with the test
    ## and we can only associate them by this id
    test = getTestFromHook(hook, hook.parent, getTestById)
    hook.id = test.id
    hook.ctx.currentTest = test

    Cypress.action("runner:hook:start", wrap(hook))

  _runner.on "hook end", (hook) ->
    hookName = getHookName(hook)

    Cypress.action("runner:hook:end", wrap(hook))

  _runner.on "test", (test) ->
    setTest(test)

    return if _emissions.started[test.id]

    _emissions.started[test.id] = true

    Cypress.action("runner:test:start", wrap(test))

  _runner.on "test end", (test) ->
    return if _emissions.ended[test.id]

    _emissions.ended[test.id] = true

    Cypress.action("runner:test:end", wrap(test))

  _runner.on "pass", (test) ->
    Cypress.action("runner:pass", wrap(test))

  ## if a test is pending mocha will only
  ## emit the pending event instead of the test
  ## so we normalize the pending / test events
  _runner.on "pending", (test) ->
    ## do nothing if our test is skipped
    return if test._ALREADY_RAN

    if not fired(TEST_BEFORE_RUN_EVENT, test)
      fire(TEST_BEFORE_RUN_EVENT, test, Cypress)

    test.state = "pending"

    if not test.alreadyEmittedMocha
      ## do not double emit this event
      test.alreadyEmittedMocha = true

      Cypress.action("runner:pending", wrap(test))

    @emit("test", test)

    ## if this is not the last test amongst its siblings
    ## then go ahead and fire its test:after:run event
    ## else this will not get called
    tests = getAllSiblingTests(test.parent, getTestById)

    if _.last(tests) isnt test
      fire(TEST_AFTER_RUN_EVENT, test, Cypress)

  _runner.on "fail", (runnable, err) ->
    isHook = runnable.type is "hook"

    if isHook
      parentTitle = runnable.parent.title
      hookName    = getHookName(runnable)

      ## append a friendly message to the error indicating
      ## we're skipping the remaining tests in this suite
      err = $utils.appendErrMsg(
        err,
        $utils.errMessageByPath("uncaught.error_in_hook", {
          parentTitle,
          hookName
        })
      )

    ## always set runnable err so we can tap into
    ## taking a screenshot on error
    runnable.err = wrapErr(err)

    if not runnable.alreadyEmittedMocha
      ## do not double emit this event
      runnable.alreadyEmittedMocha = true

      Cypress.action("runner:fail", wrap(runnable), runnable.err)

    ## if we've already fired the test after run event
    ## it means that this runnable likely failed due to
    ## a double done(err) callback, and we need to fire
    ## this again!
    if fired(TEST_AFTER_RUN_EVENT, runnable)
      fire(TEST_AFTER_RUN_EVENT, runnable, Cypress)

    if isHook
      ## if a hook fails (such as a before) then the test will never
      ## get run and we'll need to make sure we set the test so that
      ## the TEST_AFTER_RUN_EVENT fires correctly
      hookFailed(runnable, runnable.err, hookName, getTestById, setTest)

create = (specWindow, mocha, Cypress, cy) ->
  _id = 0
  _uncaughtFn = null

  _runner = mocha.getRunner()
  _runner.suite = mocha.getRootSuite()

  specWindow.onerror = ->
    err = cy.onSpecWindowUncaughtException.apply(cy, arguments)

    ## err will not be returned if cy can associate this
    ## uncaught exception to an existing runnable
    return true if not err

    todoMsg = ->
      if not Cypress.config("isTextTerminal")
        "Check your console for the stack trace or click this message to see where it originated from."

    append = ->
      _.chain([
        "Cypress could not associate this error to any specific test.",
        "We dynamically generated a new test to display this failure.",
        todoMsg()
      ])
      .compact()
      .join("\n\n")

    ## else  do the same thing as mocha here
    err = $utils.appendErrMsg(err, append())

    throwErr = ->
      throw err

    ## we could not associate this error
    ## and shouldn't ever start our run
    _uncaughtFn = throwErr

    ## return undefined so the browser does its default
    ## uncaught exception behavior (logging to console)
    return undefined

  ## hold onto the _runnables for faster lookup later
  _stopped = false
  _test = null
  _tests = []
  _testsById = {}
  _testsQueue = []
  _testsQueueById = {}
  _runnables = []
  _logsById = {}
  _emissions = {
    started: {}
    ended:   {}
  }
  _startTime = null

  getId = ->
    ## increment the id counter
    "r" + (_id += 1)

  setTestsById = (tbid) ->
    _testsById = tbid

  setTests = (t) ->
    _tests = t

  getTests = ->
    _tests

  onRunnable = (r) ->
    _runnables.push(r)

  onLogsById = (l) ->
    _logsById[l.id] = l

  getTest = ->
    _test

  setTest = (t) ->
    _test = t

  getTestById = (id) ->
    ## perf short circuit
    return if not id

    _testsById[id]

  overrideRunnerHook(Cypress, _runner, getTestById, getTest, setTest, getTests)

  return {
    grep: (re) ->
      if arguments.length
        _runner._grep = re
      else
        ## grab grep from the mocha _runner
        ## or just set it to all in case
        ## there is a mocha regression
        _runner._grep ?= defaultGrepRe

    options: (options = {}) ->
      ## TODO
      ## need to handle
      ## ignoreLeaks, asyncOnly, globals

      if re = options.grep
        @grep(re)

    normalizeAll: (tests) ->
      ## if we have an uncaught error then slice out
      ## all of the tests and suites and just generate
      ## a single test since we received an uncaught
      ## error prior to processing any of mocha's tests
      ## which could have occurred in a separate support file
      if _uncaughtFn
        _runner.suite.suites = []
        _runner.suite.tests = []

        ## create a runnable to associate for the failure
        mocha.createRootTest("An uncaught error was detected outside of a test", _uncaughtFn)

      normalizeAll(
        _runner.suite,
        tests,
        @grep(),
        setTestsById,
        setTests,
        onRunnable,
        onLogsById,
        getId
      )

    run: (fn) ->
      _startTime ?= moment().toJSON()

      _runnerListeners(_runner, Cypress, _emissions, getTestById, setTest)

      _runner.run (failures) ->
        ## if we happen to make it all the way through
        ## the run, then just set _stopped to true here
        _stopped = true

        ## TODO this functions is not correctly
        ## synchronized with the 'end' event that
        ## we manage because of uncaught hook errors
        if fn
          fn(failures, getTestResults(_tests))

    onRunnableRun: (runnableRun, runnable, args) ->
      if not runnable.id
        throw new Error("runnable must have an id", runnable.id)

      ## if this isnt a hook, then the name is 'test'
      hookName = getHookName(runnable) or "test"

      switch runnable.type
        when "hook"
          test = runnable.ctx.currentTest
        when "test"
          test = runnable

      ## if we haven't yet fired this event for this test
      ## that means that we need to reset the previous state
      ## of cy - since we now have a new 'test' and all of the
      ## associated _runnables will share this state
      if not fired(TEST_BEFORE_RUN_EVENT, test)
        fire(TEST_BEFORE_RUN_EVENT, test, Cypress)

      ## extract out the next(fn) which mocha uses to
      ## move to the next runnable - this will be our async seam
      next = args[0]

      ## our runnable is about to run, so let cy know. this enables
      ## us to always have a correct runnable set even when we are
      ## running lifecycle events
      ## and also get back a function result handler that we use as
      ## an async seam
      cy.setRunnable(runnable, hookName)

      onNext = (err) ->
        ## attach error right now
        ## if we have one
        if err
          runnable.err = wrapErr(err)

        runnableAfterRunAsync(runnable, Cypress)
        .then ->
          ## once we complete callback with the
          ## original err
          next(err)

          ## return null here to signal to bluebird
          ## that we did not forget to return a promise
          ## because mocha internally does not return
          ## the test.run(fn)
          return null

        ## if these promises fail then reset the
        ## error to that
        .catch (err) ->
          next(err)

          ## return null here to signal to bluebird
          ## that we did not forget to return a promise
          ## because mocha internally does not return
          ## the test.run(fn)
          return null

      ## TODO: handle promise timeouts here!
      ## whenever any runnable is about to run
      ## we figure out what test its associated to
      ## if its a hook, and then we fire the
      ## test:before:run:async action if its not
      ## been fired before for this test
      testBeforeRunAsync(test, Cypress)
      .catch (err) ->
        ## TODO: if our async tasks fail
        ## then allow us to cause the test
        ## to fail here by blowing up its fn
        ## callback
        fn = runnable.fn

        restore = ->
          runnable.fn = fn

        runnable.fn = ->
          restore()

          throw err
      .finally ->
        ## call the original method with our
        ## custom onNext function
        runnableRun.call(runnable, onNext)

    getStartTime: ->
      _startTime

    setStartTime: (iso) ->
      _startTime = iso

    countByTestState: (tests, state) ->
      count = _.filter tests, (test, key) ->
        test.state is state

      count.length

    setNumLogs: (num) ->
      $Log.setCounter(num)

    getEmissions: ->
      _emissions

    getTestsState: ->
      id    = _test?.id
      tests = {}

      ## bail if we dont have a current test
      return {} if not id

      ## search through all of the tests
      ## until we find the current test
      ## and break then
      for test in _tests
        if test.id is id
          break
        else
          test = wrapAll(test)

          _.each RUNNABLE_LOGS, (type) ->
            if logs = test[type]
              test[type] = _.map(logs, $Log.toSerializedJSON)

          tests[test.id] = test

      return tests

    stop: ->
      if _stopped
        return

      _stopped = true

      ## abort the run
      _runner.abort()

      ## emit the final 'end' event
      ## since our reporter depends on this event
      ## and mocha may never fire this becuase our
      ## runnable may never finish
      _runner.emit("end")

      ## remove all the listeners
      ## so no more events fire
      _runner.removeAllListeners()

    getDisplayPropsForLog: $Log.getDisplayProps

    getConsolePropsForLogById: (logId) ->
      if attrs = _logsById[logId]
        $Log.getConsoleProps(attrs)

    getSnapshotPropsForLogById: (logId) ->
      if attrs = _logsById[logId]
        $Log.getSnapshotProps(attrs)

    getErrorByTestId: (testId) ->
      if test = getTestById(testId)
        wrapErr(test.err)

    resumeAtTest: (id, emissions = {}) ->
      Cypress._RESUMED_AT_TEST = id

      _emissions = emissions

      for test in _tests
        if test.id isnt id
          test._ALREADY_RAN = true
          test.pending = true
        else
          ## bail so we can stop now
          return

    cleanupQueue: (numTestsKeptInMemory) ->
      cleanup = (queue) ->
        if queue.length > numTestsKeptInMemory
          test = queue.shift()

          delete _testsQueueById[test.id]

          _.each RUNNABLE_LOGS, (logs) ->
            _.each test[logs], (attrs) ->
              ## we know our attrs have been cleaned
              ## now, so lets store that
              attrs._hasBeenCleanedUp = true

              $Log.reduceMemory(attrs)

          cleanup(queue)

      cleanup(_testsQueue)

    addLog: (attrs, isInteractive) ->
      ## we dont need to hold a log reference
      ## to anything in memory when we're headless
      ## because you cannot inspect any logs
      return if not isInteractive

      test = getTestById(attrs.testId)

      ## bail if for whatever reason we
      ## cannot associate this log to a test
      return if not test

      ## if this test isnt in the current queue
      ## then go ahead and add it
      if not _testsQueueById[test.id]
        _testsQueueById[test.id] = true
        _testsQueue.push(test)

      if existing = _logsById[attrs.id]
        ## because log:state:changed may
        ## fire at a later time, its possible
        ## we've already cleaned up these attrs
        ## and in that case we don't want to do
        ## anything at all
        return if existing._hasBeenCleanedUp

        ## mutate the existing object
        _.extend(existing, attrs)
      else
        _logsById[attrs.id] = attrs

        { testId, instrument } = attrs

        if test = getTestById(testId)
          ## pluralize the instrument
          ## as a property on the runnable
          logs = test[instrument + "s"] ?= []

          ## else push it onto the logs
          logs.push(attrs)
  }

module.exports = {
  overrideRunnerHook

  normalize

  normalizeAll

  create
}

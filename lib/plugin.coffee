# The plugin module manages the dynamic retrieval of plugin
# javascript including additional scripts that may be requested.
forward = require './forward'

module.exports = plugin = {}

escape = (s) ->
  (''+s)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#x27;')
    .replace(/\//g,'&#x2F;')

# define loadScript that allows fetching a script.
# see example in http://api.jquery.com/jQuery.getScript/

loadScript = (url, options) ->
  console.log("loading url:", url)
  options = $.extend(options or {},
    dataType: "script"
    cache: true
    url: url
  )
  $.ajax options

scripts = []
loadingScripts = {}
getScript = plugin.getScript = (url, callback = () ->) ->
  if url in scripts
    callback()
  else
    loadScript url
      .done ->
        scripts.push url
        callback()
      .fail (_jqXHR, _textStatus, err) ->
        console.log('getScript: Failed to load:', url, err)
        callback()

# Consumes is a list
pluginsThatConsume = (capability) ->
  Object.keys(window.plugins)
    .filter (plugin) -> window.plugins[plugin].consumes
    .filter (plugin) -> window.plugins[plugin].consumes.indexOf(capability) != -1

plugin.produces = ($item) ->
  produces = $item[0].className.split(" ")
    .filter (c) -> c.indexOf("-source") != -1
    .map (c) -> "." + c
  return produces

plugin.renderFrom = (notifIndex) ->
  # (name, produces, notifIndex) ->
  #return if produces.length == 0 
  $items = $(".item").slice(notifIndex)
  # Possible optimization...
  #tonotify = []
  #produces.forEach (producer) ->
  #  tonotify = tonotify.concat(pluginsThatConsume(producer))
  #  console.log(producer, "is consumed by", tonotify)
  #console.log "need to notify", tonotify

  #consumers = []
  #for item in items.toArray()
  #  for name in tonotify
  #    if item.className.indexOf(name) != -1
  #      consumers.push(item)

  #console.log "notifIndex", notifIndex, "about to notify", $items
  
  console.log "notifIndex", notifIndex, "about to render", $items
  emitp = Promise.resolve()
  emitNextItem = (itemElems) ->
    return emitp if itemElems.length == 0
    itemElem = itemElems.shift()
    $item = $(itemElem)
    item = $item.data('item')
    emitp = emitp.then ->
      console.log 'emitting', $item, item
      return new Promise (resolve, reject) ->
        plugin.emit $item.empty(), item,
          done: () ->
          resolve()
    emitNextItem(itemElems)
  # The concat here makes a copy since we need to loop through the same
  # items to do a bind.
  emitp = emitNextItem $items.toArray()
  # Binds must be called sequentially in order to store the promises used to order bind operations.
  # Note: The bind promises used here are for ordering "bind creation".
  # The ordering of "bind results" is done within the plugin.bind wrapper.
  bindp = emitp.then ->
    promise = Promise.resolve()
    bindNextItem = (itemElems) ->
      return promise if itemElems.length == 0
      itemElem = itemElems.shift()
      $item = $(itemElem)
      item = $item.data('item')
      console.log $item, item
      promise = promise.then ->
        return new Promise (resolve, reject) ->
          plugin.getPlugin item.type, (plugin) ->
            plugin.bind $item, item
            resolve()
      bindNextItem(itemElems)
    bindNextItem($items.toArray())
  return bindp

bind = (name, pluginBind) ->
  fn = ($item, item, oldIndex) ->
    index = $('.item').index($item)
    consumes = window.plugins[name].consumes
    waitFor = Promise.resolve()
    # Wait for all items in the lineup that produce what we consume
    # before calling our bind method.
    if consumes
      deps = []
      consumes.forEach (consuming) ->
        producers = $(".item:lt(#{index})").filter(consuming)
        console.log(name, "consumes", consuming)
        console.log(producers, "produce", consuming)
        if not producers or producers.length == 0
          console.log 'warn: no items in lineup that produces', consuming
        console.log("there are #{producers.length} instances of #{consuming}")
        producers.each (_i, el) ->
          console.log("promise: ", el, el.promise)
          deps.push(el.promise)
      console.log("waiting for:", deps)
      waitFor = Promise.all(deps)
    waitFor
      .then ->
        console.log("getting promise for", name)
        bindPromise = pluginBind($item, item)
        if not bindPromise or typeof(bindPromise.then) == 'function'
          bindPromise = Promise.resolve(bindPromise)
        # This is where the "bind results" promise for the current item is stored
        $item[0].promise = bindPromise
        console.log("promise bound for", name)
      .then ->
        # If the plugin has the needed callback, subscribe to server side events
        # for the current page
        if window.plugins[name].processServerEvent
          console.log 'listening for server events', $item, item
          forward.init $item, item, window.plugins[name].processServerEvent
      .catch (e) ->
        console.log 'plugin emit: unexpected error', e
  return fn

plugin.wrap = (name, p) ->
  p.bind = bind(name, p.bind)
  return p

plugin.get = plugin.getPlugin = (name, callback) ->
  return loadingScripts[name].then(callback) if loadingScripts[name]
  loadingScripts[name] = new Promise (resolve, _reject) ->
    return resolve(window.plugins[name]) if window.plugins[name]
    getScript "/plugins/#{name}/#{name}.js", () ->
      p = window.plugins[name]
      if p
        plugin.wrap(name, p)
        return resolve(p)
      getScript "/plugins/#{name}.js", () ->
        p = window.plugins[name]
        plugin.wrap(name, p) if p
        return resolve(p)
  loadingScripts[name].then (plugin) ->
    delete loadingScripts[name]
    return callback(plugin)
  return loadingScripts[name]


plugin.do = plugin.doPlugin = (div, item, done=->, originalIndex) ->
  plugin.emit div, item, {done, originalIndex, bind: true}

plugin.emit = (div, item, {done=->, originalIndex, bind=false}) ->
  error = (ex, script) ->
    div.append """
      <div class="error">
        #{escape item.text || ""}
        <button>help</button><br>
      </div>
    """
    if item.text?
      div.find('.error').dblclick (e) ->
        wiki.textEditor div, item
    div.find('button').on 'click', ->
      wiki.dialog ex.toString(), """
        <p> This "#{item.type}" plugin won't show.</p>
        <li> Is it available on this server?
        <li> Is its markup correct?
        <li> Can it find necessary data?
        <li> Has network access been interrupted?
        <li> Has its code been tested?
        <p> Developers may open debugging tools and retry the plugin.</p>
        <button class="retry">retry</button>
        <p> Learn more
          <a class="external" target="_blank" rel="nofollow"
          href="http://plugins.fed.wiki.org/about-plugins.html"
          title="http://plugins.fed.wiki.org/about-plugins.html">
            About Plugins
            <img src="/images/external-link-ltr-icon.png">
          </a>
        </p>
      """
      $('.retry').on 'click', ->
        if script.emit.length > 2
          script.emit div, item, ->
            script.bind div, item, originalIndex if bind
            done()
        else
          script.emit div, item
          script.bind div, item, originalIndex if bind
          done()

  div.data 'pageElement', div.parents(".page")
  div.data 'item', item
  plugin.get item.type, (script) ->
    try
      throw TypeError("Can't find plugin for '#{item.type}'") unless script?
      if script.emit.length > 2
        script.emit div, item, ->
          script.bind div, item, originalIndex if bind
          done()
      else
        script.emit div, item
        script.bind div, item, originalIndex if bind
        done()
    catch err
      console.log 'plugin error', err
      error(err, script)
      done()

plugin.registerPlugin = (pluginName,pluginFn)->
  window.plugins[pluginName] = pluginFn($)

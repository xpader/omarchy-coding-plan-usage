import QtQuick

// Platform registry for coding-plan usage. This is the plugin's abstraction
// seam: the panel only ever talks to the normalized provider contract
// (documented in providers/glm/GlmProvider.qml), never to a platform API.
//
// Adding a platform = create providers/<id>/<Id>Provider.qml implementing
// the contract, drop an assets/ mark if you want one, and append one entry
// to `registry` below. Toggle platforms from shell.json via
//   "providers": { "<id>": { "enabled": false } }
Item {
  id: root

  property var settings: ({})

  readonly property var registry: [
    { id: "glm", source: Qt.resolvedUrl("providers/glm/GlmProvider.qml") },
    { id: "deepseek", source: Qt.resolvedUrl("providers/deepseek/DeepseekProvider.qml") }
  ]

  function providerEnabled(id) {
    var providers = settings && settings.providers ? settings.providers : null
    if (!providers || !providers[id]) return true
    return providers[id].enabled !== false
  }

  readonly property var enabledSpecs: {
    var specs = []
    for (var i = 0; i < registry.length; i++) {
      if (providerEnabled(registry[i].id)) specs.push(registry[i])
    }
    return specs
  }

  Instantiator {
    id: instantiator
    model: root.enabledSpecs

    delegate: Loader {
      required property var modelData
      active: true
      source: modelData.source
      onLoaded: if ("settings" in item) item.settings = root.settings
    }

    onObjectAdded: root.rebuildProviders()
    onObjectRemoved: root.rebuildProviders()
  }

  onSettingsChanged: injectSettings()

  function injectSettings() {
    for (var i = 0; i < instantiator.count; i++) {
      var loader = instantiator.objectAt(i)
      if (loader && loader.item && "settings" in loader.item)
        loader.item.settings = settings
    }
  }

  // Live provider objects. Bindings on their properties (state, windows,
  // headlinePercent, ...) update normally — these are the same Items the
  // Instantiator keeps alive.
  property var providers: []

  function rebuildProviders() {
    var list = []
    for (var i = 0; i < instantiator.count; i++) {
      var loader = instantiator.objectAt(i)
      if (loader && loader.item) list.push(loader.item)
    }
    providers = list
  }

  function providerById(id) {
    for (var i = 0; i < providers.length; i++) {
      if (providers[i] && providers[i].providerId === id) return providers[i]
    }
    return null
  }

  function refreshAll() {
    for (var i = 0; i < providers.length; i++) {
      if (providers[i] && providers[i].refresh) providers[i].refresh()
    }
  }

  // The provider holding the binding (fullest) window across all platforms —
  // what the bar pill speaks for.
  readonly property var headlineProvider: {
    var best = null
    for (var i = 0; i < providers.length; i++) {
      var p = providers[i]
      if (!p || p.state !== "ok") continue
      if (!best || p.headlinePercent > best.headlinePercent) best = p
    }
    return best
  }

  readonly property bool anyKeyMissing: {
    for (var i = 0; i < providers.length; i++) {
      if (providers[i] && providers[i].state === "no-key") return true
    }
    return false
  }
}

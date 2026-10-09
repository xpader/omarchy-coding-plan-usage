import QtQuick

// Minimal shared GET-over-XMLHttpRequest: in-flight guard, 15s timeout,
// status-code message mapping. Dumb on purpose — providers own all
// state handling via the responded/timedOut signals.
Item {
  id: fetcher

  property string url: ""
  property string authHeader: "" // full Authorization value, "" = none
  property var activeXhr: null
  readonly property bool busy: activeXhr !== null

  signal responded(int status, string text)
  signal timedOut()

  function get() {
    if (busy || url === "") return
    var xhr = new XMLHttpRequest()
    activeXhr = xhr
    timeout.restart()
    xhr.onreadystatechange = function() {
      if (xhr !== fetcher.activeXhr || xhr.readyState !== XMLHttpRequest.DONE) return
      fetcher.activeXhr = null
      timeout.stop()
      fetcher.responded(xhr.status, xhr.responseText)
    }
    xhr.open("GET", url)
    if (authHeader !== "") xhr.setRequestHeader("Authorization", authHeader)
    xhr.setRequestHeader("Accept", "application/json")
    xhr.send()
  }

  function statusMessage(status) {
    if (status === 401) return "Invalid API key"
    if (status === 402) return "Payment required"
    if (status === 429) return "Rate limited"
    if (status > 0) return "HTTP " + status
    return "Network request failed"
  }

  Timer {
    id: timeout
    interval: 15000
    onTriggered: {
      if (fetcher.activeXhr === null) return
      fetcher.activeXhr = null // the readystatechange guard bails on mismatch
      fetcher.timedOut()
    }
  }
}

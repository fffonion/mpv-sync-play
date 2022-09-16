/*
 * vod_broker.js
 *
 * Description: sync playback position between multiple mpv instances
 * Version:     1.0.0
 * Author:      fffonion
 * URL:         https://github.com/fffonion/mpv-sync-play
 * License:     Apache License, Version 2.0
 */

'use strict';

// >= 0.33.0
mp.module_paths.push(mp.get_script_directory());

var utils = mp.utils
var read_options = mp.options.read_options

var VERSION = "1.0.0"

var ident = "client-" + Math.floor(Math.random() * 90000) + 10000

var tmpDir

var getTmpDir = function () {
    if (!tmpDir) {
        var temp = mp.utils.getenv("TEMP") ||
            mp.utils.getenv("TMP") ||
            mp.utils.getenv("TMPDIR");
        if (temp) {
            tmpDir = temp;
        } else {
            tmpDir = "/tmp";
        }
    }
    return tmpDir;
}

var fileExists = function (path) {
    if (mp.utils.file_info) { // >= 0.28.0
        return mp.utils.file_info(path);
    }
    try {
        mp.utils.read_file(path, 1)
    } catch (e) {
        return false;
    }
    return true;
}

var testDownloadTool = function () {
    var _UA = mp.get_property("mpv-version").replace(" ", "/") + " broker-js-" + VERSION;
    var UA = "User-Agent: " + _UA;
    var cmds = [
        ["curl", "-SLs", "-H", UA, "--max-time", "5", "-d"],
        ["wget", "-q", "--header", UA, "-O", "-", "--post-data"],
        ["powershell", " Invoke-WebRequest -UserAgent \"" + _UA + "\"  -ContentType \"application/json; charset=utf-8\" -Method POST -URI"]
    ];
    // var _winhelper = mp.utils.split_path(mp.get_script_file())[0] + "win-helper.vbs";
    // if (fileExists(_winhelper)) {
    //     cmds.push(["cscript", "/nologo", _winhelper, _UA]);
    // };
    for (var i = 0; i < cmds.length; i++) {
        var result = mp.utils.subprocess({
            args: [cmds[i][0], '-h'],
            cancellable: false
        });
        if (typeof result.stdout === 'string' && result.status != -1) {
            mp.msg.info("selected: ", cmds[i][0]);
            return cmds[i];
        }
    }
    return null;
}

var post = function (args, body, url) {
    args = args.slice();

    if (args[0] == "powershell") {
        args[args.length - 1] += "\"" + url + "\" -Outfile \"" + saveFile + "\" -Body \"" + body + "\"";
    } else {
        args.push(body, url);
    }

    var result = mp.utils.subprocess({
        args: args,
        cancellable: true
    });

    if (result.stderr || result.status != 0) {
        throw (result.stderr ||
            ("subprocess exit with code: " + result.status + ", stderr: " + result.stderr))
    }

    if (args[0] == "powershell" || args[0] == "cscript") {
        return mp.utils.read_file(saveFile)
    } else {
        return result.stdout
    }
}



var RPC = {
    play: function (url) {
        mp.msg.info("stream open filename ", mp.get_property_native("stream-open-filename", ""))
        if (mp.get_property_native("stream-open-filename", "") != url) {
            mp.msg.info("set file to " + url)
            // mp.set_property_native("stream-open-filename", url)
            mp.commandv('loadfile', url, 'replace')
        }
    },

    pause: function (pause) {
        mp.set_property_native("pause", pause)
    },

    stop: function () {
        // mp.set_property_native("pause", pause)
    },

    position: function (position_str) {
        var parts = position_str.split("|")
        var position = parseFloat(parts[0])
        var ts = parseFloat(parts[1])
        position = Date.now()/1000 - ts + position
        var cur = mp.get_property_native("time-pos")
        if (!cur || Math.abs(position - cur) > 1) {
            mp.msg.info("adjusting position: " + position)
            mp.set_property_native("time-pos", position)
        }
    },
}

var BROKER = {}

var BROKER = function (options) {
    var options = options || {}
    var tbl = {}
    this.broker_url = options.broker_url
    this.room_id = options.room_id
    this.sync_interval = options.sync_interval

    this.is_host = true // default to host
    this.lazy_reposition = false
}

BROKER.prototype.rpc = function (method, args) {
    if (!this.cmd) {
        this.cmd = testDownloadTool();
    }
    if (!this.cmd) {
        mp.msg.error("no wget or curl found");
        return;
    }

    var body = JSON.stringify({
        method: method,
        args: args
    })
    mp.msg.info("RPC: " + method)
    mp.msg.verbose("RPC: " + body)

    try {
        var ret = post(this.cmd, body, this.broker_url + "/" + this.room_id)
    } catch (e) {
        mp.msg.error("RPC request error: " + e)
        return
    }

    try {
        var decoded = JSON.parse(ret)
    } catch (e) {
        mp.msg.error("RPC parse error: " + e + " raw body is: " + ret)
        return
    }

    if (decoded.code > 0) {
        mp.msg.error("RPC return error: " + decoded.code + ", message: " + decoded.error)
        return
    }

    mp.msg.verbose("RPC: OK " + ret)

    return decoded.data
}


function sleep(time) {
    var now = mp.get_time_ms()
    while (mp.get_time_ms() - now < time) {}
}

BROKER.prototype.join = function () {
    var timeout = 300 // try 5 minutes
    for (var i = 1; i < timeout / 5; i++) {
        var start = this.syncDown()
        if (start) {
            break
        }
        sleep(5)
    }
}

BROKER.prototype.syncUp = function () {
    if (mp.get_property("seekable") && this.is_host) {
        var position = mp.get_property_number("time-pos")
        var url = mp.get_property("stream-open-filename", "")
        var pause = mp.get_property_native("pause")
        if (position != undefined) {
            this.rpc("sync", [ ident, position, Date.now()/1000, url, pause ])
        }
    }
}

BROKER.prototype.syncDown = function (interval) {
    if (this.is_host) {
        return
    }

    var start_play = false
    var state = this.rpc("get_state", interval? [ interval ] : [])

    if (state) {
        mp.msg.verbose(JSON.stringify(state))
        for (var i = 0; i < state.length; i++) {
            var s = state[i]
            if (s[0] == "play") {
                start_play = true
            } else if (s[0] == "position") {
                this.lazy_reposition = s[1]
            }
            if (s[0] == "host") {
                if (s[1] == ident) {
                    if (!this.is_host) {
                        mp.osd_message("claimed the host", 3)
                        mp.msg.info("claimed the host")
                    }
                }
                this.is_host = s[1] == ident
            } else if (RPC[s[0]]) {
                RPC[s[0]](s[1])
            } else
                mp.msg.warn("unknown state: " + s[1])
        }
    }

    return start_play
}

BROKER.prototype.checkLazyReposition = function () {
    if (this.lazy_reposition) {
        mp.msg.info("lazy reposition: " + this.lazy_reposition)
        RPC.position(this.lazy_reposition)
        this.lazy_reposition = false
    }
}


(function () {
    var userConfig = {
        broker_url: "http://broker.vod.yooooo.us",
        room_id: 1,
        sync_interval: 5,
    };
    read_options(userConfig, "vod_broker")

    // Create && initialize the media browser instance.
    try {
        var broker = new BROKER({
            broker_url: userConfig["broker_url"],
            room_id: userConfig["room_id"],
            sync_interval: userConfig["sync_interval"],
        });
    } catch (e) {
        mp.msg.error('BROKER: ' + e + '.');
        mp.osd_message('BROKER: ' + e + '.', 3);
        throw e; // Critical init error. Stop script execution.
    }

    mp.msg.info("script loaded, default broker. " + broker.broker_url + "/" + broker.room_id)

    var prefix = "broker://"

    mp.add_hook("on_load_fail", 10, function () {
        var url = mp.get_property("stream-open-filename", "")
        if (url.search(prefix) == -1) {
            return
        }
        broker.is_host = false
        broker.join(url.substring(prefix.length + 2))
    })

    mp.register_event("start-file", function () {
        var path = mp.get_property("stream-open-filename", "")
        if (path != "" && path.search(prefix) == -1) {
            broker.rpc("play", [ path ])
        }
    })

    // mp.register_event("}-file", function() {
    //   // } file
    // })

    mp.observe_property("pause", "bool", function (name, value) {
        broker.rpc("pause", [ value ])
    })

    mp.register_event("seek", function () {
        broker.syncUp()
    })

    var broker_auto_joined = false
    mp.observe_property("idle-active", "bool", function (name, value) {
        // value is true when mpv is idle
        if (value == true && !broker_auto_joined) {
            broker_auto_joined = true
            broker.join(userConfig.room_id)
        }
    })

    mp.register_event("file-loaded", function () {
        broker.checkLazyReposition()
    })

    // blocking query
    var timer1 = setInterval(function () {
        broker.syncDown(parseFloat(userConfig.sync_interval))
    }, 100)

    // timely sync
    var timer2 = setInterval(function () {
        broker.syncUp()
    }, userConfig.sync_interval * 1000)
})();
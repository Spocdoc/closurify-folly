fs = require 'fs'

getModTime = (filePath, cb) ->
  fs.stat filePath, (err, stat) ->
    return cb(err) if err?
    cb null, stat.mtime.getTime()

module.exports = (fn) ->
  cacheTimes = {}
  cacheResults = {}

  (filePath, cb) ->
    getModTime filePath, (err, mtime) ->
      return cb(err) if err?
      return cb(null, cacheResults[filePath]) if cacheTimes[filePath] is mtime

      fn filePath, (err, result) ->
        return cb(err) if err?
        cacheTimes[filePath] = mtime
        cacheResults[filePath] = result
        cb null, result


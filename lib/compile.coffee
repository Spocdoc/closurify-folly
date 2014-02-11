# The MIT License
# 
# Copyright (c) 2011 Tim Smart
# 
# Permission is hereby granted, free of charge, to any person obtaining a
# copy of this software and associated documentation files
# (the "Software"), to deal in the Software without restriction,
# including without limitation the rights to use, copy, modify, merge,
# publish, distribute, sublicense, and/or sell copies of the Software, and
# to permit persons to whom the Software is furnished to do so, subject to
# the following conditions:
# 
# The above copyright notice and this permission notice shall be included
# in all copies or substantial portions of the Software.
# 
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
# OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
# MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
# IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
# CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
# TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
# SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

spawn = require('child_process').spawn
path  = require 'path'

JAVA_PATH = exports.JAVA_PATH = 'java'
JAR_PATH  = exports.JAR_PATH  = path.join __dirname, 'vendor/compiler.jar'
OPTIONS   = exports.OPTIONS   = {}

module.exports = (input, options, callback) ->
  if typeof options is 'function'
    callback = options
    options  = OPTIONS
  else
    result = {}
    result[k] = v for k,v of OPTIONS
    result[k] = v for k,v of options
    options = result

  args = [
    '-jar'
    options.jar || JAR_PATH
  ]

  delete options.jar

  for key, value of options
    key = "--#{key}"
    if Array.isArray value
      args.push key, val for val in value
    else
      args.push key, value

  compiler = spawn JAVA_PATH, args
  exitCode = 0
  stdout = ''
  stderr = ''
  waiting = 3

  finish = ->
    (error = new Error stderr).code = exitCode if exitCode
    callback error, stdout, stderr

  compiler.stdout.setEncoding 'utf8'
  compiler.stderr.setEncoding 'utf8'

  compiler.stdout.on 'data', (data) ->
    stdout += data if data

  compiler.stdout.on 'end', (data) ->
    stdout += data if data
    finish() unless --waiting

  compiler.stderr.on 'data', (data) ->
    stderr += data

  compiler.stderr.on 'end', (data) ->
    stderr += data if data
    finish() unless --waiting

  compiler.on 'exit', (code) ->
    exitCode = code
    finish() unless --waiting
    
  compiler.stdin.end input

utils = require './utils'
async = require 'async'
ug = require 'uglify-js-fork'

module.exports = replaceRequires = (ast, cb) ->
  paths = []
  ast.exportNames ||= {}

  async.waterfall [
    (next) ->
      ast.transform utils.transformRequires (node) ->
        node.pathIndex = -1 + paths.push utils.resolveRequirePath(node.start.file, node)
        node

      async.mapSeries paths, async.compose(utils.getInode,utils.resolveExtension), next

    (inodes, next) ->
      ast.transform utils.transformRequires (node) ->
        inode = inodes[node.pathIndex]

        unless name = ast.exportNames[inode]
          ret = new ug.AST_Sub
            start: node.start
            end: node.end
            expression: new ug.AST_SymbolRef
              name: 'window'
            property: new ug.AST_String
              value: "req#{inode}"
          ug.AST_Node.warn "Replacing require node {replace} with {with} -- no export found", {replace: node.print_to_string(), with: ret.print_to_string()}
          ret
        else
          new ug.AST_SymbolRef
              start: node.start
              end: node.end
              name: name

      next null, ast
  ], cb

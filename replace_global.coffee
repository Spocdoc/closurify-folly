ug = require 'uglify-js-fork'

transformGlobal = (fn) ->
  new ug.TreeTransformer (node) ->
    if node.TYPE is 'SymbolRef' and node.name is 'global' and node.undeclared?()
      fn node

module.exports = (ast) ->
  ast.figure_out_scope()
  ast = ast.transform transformGlobal (node) ->
    new ug.AST_SymbolRef
        start: node.start,
        end: node.end,
        name: 'window'


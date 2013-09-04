utils = require 'js_ast_utils'
async = require 'async'
_ = require 'lodash-fork'
ug = require 'uglify-js-fork'

buildRequire = (ast, requires, walker, inode, node) ->
  unless name = ast.exportNames[inode]
    if requires
      ret = new ug.AST_Sub
        start: node.start
        end: node.end
        expression: new ug.AST_SymbolRef
          name: 'window'
        property: new ug.AST_String
          value: "req#{inode}"
    else if walker.parent() instanceof ug.AST_Call and node is walker.parent().expression
      throw new Error "Encountered function call on undefined require in #{walker.parent().start.file}: #{walker.parent().print_to_string(debug: true)}"
    else
      ret = new ug.AST_UnaryPrefix
        operator: 'void'
        expression: new ug.AST_Number value: 0
    ug.AST_Node.warn "Replacing require node {replace} with {with} in {filePath} -- no export found",
      replace: node.print_to_string(debug: true)
      with: ret.print_to_string()
      filePath: node.start.file
    ret
  else
    new ug.AST_SymbolRef
        start: node.start
        end: node.end
        name: name

setInodes = (ast) ->
  err = null

  utils.transformRequires ast, (node) ->
    return node if err?

    try
      node.inode = _.getInodeSync utils.resolveRequireCall node
    catch _error
      err = _error

    node

  throw err if err?

replaceRequires = (ast) ->
  varNode = null
  err = null

  ast.transform walker = new ug.TreeTransformer (node, descend) ->
    return node if err?

    try
      if (node instanceof ug.AST_Assign) and node.left instanceof ug.AST_SymbolRef and node.operator is '=' and utils.isRequire(node.right)
        inode = node.right.inode
        if (leftInode = node.left.closurifyExport)? and ast.exportNames[leftInode]?
          ast.exportNames[leftInode] = ast.exportNames[inode]
        node.left.thedef.closurifyRequireRef = inode

        if walker.parent().TYPE is 'SimpleStatement'
          walker.parent().closurifyRequireDel = true
        else
          buildRequire ast, requires, walker, inode, node

      else if utils.isRequire node
        inode = node.inode
        if walker.parent().TYPE is 'SimpleStatement' and !ast.exportNames[inode]
          walker.parent().closurifyRequireDel = true
          return node
        buildRequire ast, requires, walker, inode, node

      else if node instanceof ug.AST_Var
        prev = varNode
        varNode = node
        descend node, this

        if defs = node.definitions
          for def in defs.splice(0) when !def.closurifyRequireDef
            node.definitions.push def

        varNode = prev

        unless node.definitions?.length
          new ug.AST_EmptyStatement
            start: node.start
            end: node.end
        else
          node

      else if varNode and node instanceof ug.AST_VarDef and utils.isRequire node.value
        inode = node.value.inode
        if (nameInode = node.name.closurifyExport)? and ast.exportNames[nameInode]?
          ast.exportNames[nameInode] = ast.exportNames[inode]
        node.name.thedef.closurifyRequireRef = inode
        node.closurifyRequireDef = true
        node

      else if node.TYPE is 'SimpleStatement'
        descend node, this
        if node.closurifyRequireDel
          new ug.AST_EmptyStatement
            start: node.start
            end: node.end
        else
          node

    catch _error
      err = _error
      node

  throw err if err?

replaceRefs = (ast, requires) ->
  err = null

  ast.transform walker = new ug.TreeTransformer (node, descend) ->
    return node if err?

    try
      if node instanceof ug.AST_SymbolRef and inode = node.thedef?.closurifyRequireRef
        buildRequire ast, requires, walker, inode, node
    catch _error
      err = _error
      node

  throw err if err?

module.exports = (ast, requires) ->
  ast.figure_out_scope()
  ast.exportNames ||= {}

  setInodes ast
  replaceRequires ast, requires
  replaceRefs ast, requires
  return


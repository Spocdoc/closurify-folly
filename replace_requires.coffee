utils = require 'js_ast_utils'
async = require 'async'
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
    else if walker.parent() instanceof ug.AST_Call
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

module.exports = replaceRequires = (ast, requires, cb) ->
  paths = []
  ast.exportNames ||= {}

  ast.figure_out_scope()
  varNode = null
  err = null

  async.waterfall [
    (next) ->
      utils.transformRequires ast, (node) ->
        node.pathIndex = -1 + paths.push utils.resolveRequirePath node
        node

      async.mapSeries paths, async.compose(utils.getInode,utils.resolveExtension), next

    (inodes, next) ->
      ast.transform walker = new ug.TreeTransformer (node, descend) ->
        return node if err?

        try
          if (node instanceof ug.AST_Assign) and node.left instanceof ug.AST_SymbolRef and node.operator is '=' and utils.isRequire(node.right)
            inode = inodes[node.right.pathIndex]
            node.left.thedef.closurifyRequireRef = inode

            if walker.parent().TYPE is 'SimpleStatement'
              walker.parent().closurifyRequireDel = true
            else
              buildRequire ast, requires, walker, inode, node

          else if utils.isRequire node
            inode = inodes[node.pathIndex]
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
            node.closurifyRequireDef = true
            node.name.thedef.closurifyRequireRef = inodes[node.value.pathIndex]
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

        return next err if err?

        ast.transform walker = new ug.TreeTransformer (node, descend) ->
          return node if err?

          try
            if node instanceof ug.AST_SymbolRef and inode = node.thedef?.closurifyRequireRef
              buildRequire ast, requires, walker, inode, node
          catch _error
            err = _error
            node


      next err, ast
  ], cb

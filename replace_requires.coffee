utils = require 'js_ast_utils'
async = require 'async'
ug = require 'uglify-js-fork'

buildRequire = (ast, inode, node) ->
  unless name = ast.exportNames[inode]
    ret = new ug.AST_Sub
      start: node.start
      end: node.end
      expression: new ug.AST_SymbolRef
        name: 'window'
      property: new ug.AST_String
        value: "req#{inode}"
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

module.exports = replaceRequires = (ast, cb) ->
  paths = []
  ast.exportNames ||= {}

  ast.figure_out_scope()
  varNode = null

  async.waterfall [
    (next) ->
      ast.transform utils.transformRequires (node) ->
        node.pathIndex = -1 + paths.push utils.resolveRequirePath(node.start.file, node)
        node

      async.mapSeries paths, async.compose(utils.getInode,utils.resolveExtension), next

    (inodes, next) ->
      ast.transform walker = new ug.TreeTransformer (node, descend) ->
        if (node instanceof ug.AST_Assign) and node.left instanceof ug.AST_SymbolRef and node.operator is '=' and 'client' is utils.isRequire(node.right)
          inode = inodes[node.right.pathIndex]
          node.left.thedef.closurifyRequireRef = inode

          if walker.parent().TYPE is 'SimpleStatement'
            walker.parent().closurifyRequireDel = true
          else
            buildRequire ast, inode, node

        else if requireType = utils.isRequire node
          if requireType is 'client'
            inode = inodes[node.pathIndex]
            buildRequire ast, inode, node
          else if walker.parent().TYPE is 'SimpleStatement'
            walker.parent().closurifyRequireDel = true
          else
            return new ug.AST_UnaryPrefix
              operator: 'void'
              expression: new ug.AST_Number value: 0

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

        else if varNode and node instanceof ug.AST_VarDef and 'client' is utils.isRequire node.value
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

      ast.transform new ug.TreeTransformer (node, descend) ->
        if node instanceof ug.AST_SymbolRef and inode = node.thedef?.closurifyRequireRef
          buildRequire ast, inode, node

      next null, ast
  ], cb

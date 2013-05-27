var MOZ_SourceMap = require('source-map');

function defaults(args, defs, croak) {
    if (args === true)
        args = {};
    var ret = args || {};
    if (croak) for (var i in ret) if (ret.hasOwnProperty(i) && !defs.hasOwnProperty(i))
        throw new DefaultsError("`" + i + "` is not a supported option", defs);
    for (var i in defs) if (defs.hasOwnProperty(i)) {
        ret[i] = (args && args.hasOwnProperty(i)) ? args[i] : defs[i];
    }
    return ret;
};

// modified from uglify source
function SourceMap(options) {
    options = defaults(options, {
        file : null,
        root : null,
        orig : null,
    });
    var generator = new MOZ_SourceMap.SourceMapGenerator({
        file       : options.file,
        sourceRoot : options.root
    });

    if (options.content) {
        var k, v;
        for (k in options.content) {
            v = options.content[k];
            generator.setSourceContent(k, v);
        }
    }

    var orig_map = void 0;
    if (options.orig) {
        orig_map = {};

        var k, v;
        for (k in options.orig) {
            v = options.orig[k];
            orig_map[k] = new MOZ_SourceMap.SourceMapConsumer(v);
        }
    }
    
    function add(source, gen_line, gen_col, orig_line, orig_col, name) {
        var map = orig_map && orig_map[source];
        if (map) {
            var info = map.originalPositionFor({
                line: orig_line,
                column: orig_col
            });
            source = info.source;
            orig_line = info.line;
            orig_col = info.column;
            name = info.name;
        }
        generator.addMapping({
            generated : { line: gen_line, column: gen_col },
            original  : { line: orig_line, column: orig_col },
            source    : source,
            name      : name
        });
    };
    return {
        add        : add,
        get        : function() { return generator },
        toString   : function() { return generator.toString() }
    };
};

module.exports = SourceMap;

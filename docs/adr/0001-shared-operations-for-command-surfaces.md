# Share operations across command surfaces

Bau exposes capabilities through multiple command surfaces, including human-oriented command-line invocation and tool-oriented protocol invocation. We decided that command surfaces adapt input and output, while operations own behavior, so the same Bau capability should not be reimplemented separately for each surface.

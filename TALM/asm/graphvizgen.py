# FlowASM - A Trebuchet assembler for TALM's dataflow graphs.
# Authors - Tiago A.O.A. <tiagoaoa@cos.ufrj.br> Leandro J. Marzulo <lmarzulo@cos.ufrj.br>
#
# THIS IS NOT AN OFFICIAL RELEASE
# DO NOT COPY OR DISTRIBUTE
#


import re

class graphgen:

        def __init__(self, output):
                self.output = output
                self.edges = ""
                output.write('digraph G {\n')

        def start(self):
                pass
        def exit(self):
                output = self.output
                output.write(self.edges)
                output.write('}\n')
                output.close()



        def print_edge(self, dest, source, num):
                if isinstance(source, list):
                        sources = source
                else:
                        sources = [source]

                for source in sources:
                        sourceport = "0"
                        if source.find('.') > 0:
                                sourceport = source.split('.')[1]
                                source = source.split('.')[0]
                        if (re.match("[aA-zZ]", source)):
                                
                                self.edges += '%s -> %s\n' %(source, dest)
                                self.edges += '[label = "(%s,%s)", fontsize=10]\n' %(sourceport.upper(),num)

                self.output.write
        def asmline(self, tks):
                output = self.output
                
                #output.write("%s %s\n" %(tks[0], tks[1]))
                op = tks[0]
                name = tks[1]
                
                output.write('node [shape=box, style=rounded, fontsize=12];\n')
                output.write('node [label="%s %s"] %s;\n' %(op, name, name))
                for (num, source) in map(None, range(len(tks[2:])),tks[2:]):
                    print("Gerando aresta de %s" %source)
                    self.print_edge(tks[1], source, num)

# TALM/FlowASM — Architecture and Language for Multi-threading
#
# Copyright (C) 2010-2026  Tiago A.O. Alves <tiago@ime.uerj.br>
#                           Leandro Marzulo <lmarzulo@cos.ufrj.br>
#
# This file is part of TALM.
#
# TALM is free software: you can redistribute it and/or modify it
# under the terms of the GNU Lesser General Public License as
# published by the Free Software Foundation, either version 3 of
# the License, or (at your option) any later version.
#
# TALM is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public
# License along with TALM. If not, see <https://www.gnu.org/licenses/>.


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

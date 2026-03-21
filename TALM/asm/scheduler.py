# FlowASM - A Trebuchet assembler for TALM's dataflow graphs.
# Authors - Tiago A.O.A. <tiagoaoa@cos.ufrj.br> Leandro J. Marzulo <lmarzulo@cos.ufrj.br>
#
# THIS IS NOT AN OFFICIAL RELEASE
# DO NOT COPY OR DISTRIBUTE
#



import re
import random
import sys
import debug

DEFAULT_COST = 100
DEFAULT_SUPER_AVGTIME = 1000
DEFAULT_SIMPLE_AVGTIME = 5

SUPER_OPS = ('super', 'specsuper', 'superi', 'specsuperi')
INCTAG_OPS = ('inctag', 'inctagi')

class flist(list):
        """Specialized list to use l.remove() as part of a statement"""
        def remove(self, item):
                if isinstance(item, list):
                        for x in item: self.remove(x)
                else:
                        super(flist, self).remove(item)
                return self #Returns the list itself


        def __sub__(self, other):
                return flist(self).remove(other)

class InstNode:
        def __init__(self, tks, avgtimes):
                self.name = tks[1]
                self.op = tks[0]
                (self.sources, self.input_num) = self.getsources(tks)
                self.dests = []
                self.n_inedges = 0
                self.min_start = 0
        

                if self.op in ('super', 'specsuper', 'superi', 'specsuperi') and int(tks[2]) in avgtimes: #tks[2] is the blocknumber
                        blocknumber = int(tks[2]) #blocknumber of the superinstruction
                        debug.print_debug("INFO", "AVGTIME for %s blocknum %d: %d" %(self.op, blocknumber, avgtimes[blocknumber]))
                        self.avgtime = avgtimes[blocknumber]
                else:

                        if self.op in ('super', 'specsuper', 'superi', 'specsuperi'):
                                debug.print_debug("INFO", "Forcing super AVGTIME %s" %self.op)
                                self.avgtime = DEFAULT_SUPER_AVGTIME
                        else:
                                debug.print_debug("INFO", "Regular AVGTIME %s" %self.op)
                                self.avgtime = DEFAULT_SIMPLE_AVGTIME

                                if self.op == 'const': #for testing
                                        self.avgtime = 1        


        def getsources(self, tks):
                sources = []
                input_num = 0

                if self.is_super():
                        start = 4
                else:
                        start = 2
                for operand in tks[start:]:
                        if isinstance(operand, list) or re.match("^[aA-zZ]", operand):
                                input_num += 1
                                sources += [operand]

                return (sources,input_num)



        def comp_prob(self, sched): #compute the probabilitty of instr's execution
                instr = self
                outprob = 1

                eprobs = sched.edgeprobs
                #for inport in range(instr.inport_num):
                inport = 0
                """we are using the probability of only one of the input ports, see the comment on the SteerNode class."""
                if instr.input_num > 0:
                        inedges = [(si, sp, di, dp) for (si, sp, di, dp) in sched.edges if di == instr and dp == inport]
                        #outprob *= reduce(lambda acc,p: acc+p, [sched.edgeprobs[e] for e in inedges])
                
                        outprob = reduce(lambda acc,p: acc+p, [sched.edgeprobs[e] for e in inedges])
        


                outedges = [(si, sp, di, dp) for (si, sp, di, dp) in sched.edges if si == instr]                        
                for edge in outedges:   
                        sched.edgeprobs[edge] = outprob

                return outprob


        def is_super(self):
                return self.op in SUPER_OPS

        def is_inctag(self):
                return self.op in INCTAG_OPS
class SteerNode(InstNode):

        def comp_probs_cond(self, sched, boolval):
                port = boolval and "t" or "f"
                debug.print_debug("INFO", "Steer Node!!! Para porta %d"  %boolval)

                instr = self
                eprobs = sched.edgeprobs

                inedges = [[(si, sp, di, dp) for (si, sp, di, dp) in sched.edges if di == instr and dp == 0]]
                
                
#               inedges += [[(si, sp, di, dp) for (si, sp, di, dp) in sched.edges if di == instr and dp == 1]]

#               outprob = reduce(lambda acc,p: acc+p, [sched.edgeprobs[e] for e in inedges[1]])
                
                """commented out, since we are only using the probabily of one of the input ports,
                assuming that the dataflow graph is well-formed."""

                debug.print_debug("INFO", [(si.name, sp, di.name) for (si, sp, di, dp) in inedges[0]])
                conds = [eprobs[(si, sp, di, dp)]*sched.getvarprob(si.name, boolval) for (si, sp, di, dp) in inedges[0]] 
                debug.print_debug("INFO", conds)
                
                outprob = reduce(lambda acc,p: acc+p, conds)
                
                outedges = [(si, sp, di, dp) for (si, sp, di, dp) in sched.edges if si == instr and sp == port]
                #debug.print_debug("INFO", "Steer outprob: %s %s" %(si.name, sched.getvarprob(si.name, boolval)))
                for edge in outedges:
                        sched.edgeprobs[edge] = outprob


                return outprob



        def comp_prob(self, sched):
                return (self.comp_probs_cond(sched, True) + self.comp_probs_cond(sched, False))
        
        



class Processor:
        def __init__(self, index, num_procs):
                self.comm_cost =  [p != index and DEFAULT_COST or 0 for p in range(num_procs)]
                self.mkspan = 0
                self.index = index

class GraphBuilder:
        

        def __init__(self, num_procs):
                
                self.instructions = {} 
                self.ordered_instructions = []

                self.dests = {}
                self.edges = []
                self.edgeprobs = {}
                self.instcount = 0
                
                #num_procs = 5 #TODO: must come from a parameter

                self.processors = [Processor(index, num_procs) for index in range(num_procs)]
                self.mkspan = [0 for i in range(num_procs)]


        def start(self):
                pass
        def exit(self):
                #debug.print_debug("INFO", "GraphBuilder: %s" %self.edges)
                #debug.print_debug("INFO", self.instructions)
                debug.print_debug("INFO", "Autoplacement: Building graph")
                self.build_graph(self.instructions, self.edges)

                debug.print_debug("INFO", "Autoplacement: Initiating autoplacement")
                self.traverse_graph(self.instructions)
                debug.print_debug("INFO", "Finish traversing")
                debug.print_debug("INFO", "Placement:")
                for (name, instr) in [(i.name, i) for i in self.ordered_instructions]:
                        debug.print_debug("INFO", "%s: %d (p = %d)" %(name, instr.proc.index, instr.priority) )

                placement = [instr.proc.index for instr in self.ordered_instructions]
                
                debug.print_debug("INFO", "Manual Placement: %s" %placement)
                
                debug.print_debug("INFO", "mkspans:")
                for proc in self.processors:
                        debug.print_debug("INFO", "%s: %f" %(proc.index, proc.mkspan))
                debug.print_debug("INFO", "Edge probs: %s" %[(s[0][0].name, s[0][2].name, s[1]) for s in self.edgeprobs.items()])
                self.writefile(self.outfile, placement)         


        def writefile(self, file, placement):
                file.write("%d\n" %len(placement))
                for inst in placement:
                        file.write("%d\n" %inst)
                file.close()



        def getvarprob(self, var, boolval):
                profile = self.profile
                debug.print_debug("INFO", "getvarprob")
                if var in profile.varprobs:
                        debug.print_debug("INFO", "P(%s = 1) = %f" %(var, profile.varprobs[var]))
                        return boolval and profile.varprobs[var] or (1 - profile.varprobs[var])

                else:
                        debug.print_debug("INFO", "Error: no probability for control variable '%s' was stored" %var)
                        return None


        def choose_proc(self, instr):
                min_start = sys.maxint
                
                bestproc = -1   
                plist = self.processors
                
                srclist = [(si, si.proc, self.edgeprobs[(si, sp, di, dp)]) for (si, sp, di, dp) in self.edges if di == instr]
                for proc in plist:
                        debug.print_debug("INFO", "in proc %d: mkspan %f - edges %s" %(proc.index, proc.mkspan, [(si.min_end + sp.comm_cost[proc.index])*prob for (si, sp, prob) in srclist]))
                        #tmpstart = max([0] + [(si.min_end + sp.comm_cost[proc.index])*prob for (si, sp, prob) in srclist])
                        if len(srclist) > 0: 
                                (maxsi, maxsp, maxprob) = max(srclist, key=lambda item: (item[0].min_end + item[1].comm_cost[proc.index]) * item[2])
                                        #si = source instruction ; sp = source processor, 
                                        #which is the processor in which the source instruction was placed      
                        
                                tmpstart = maxsi.min_end + maxsp.comm_cost[proc.index]
                                debug.print_debug("INFO", "tmpstart: %f %f %f" %(tmpstart, maxsi.min_end, maxsp.comm_cost[proc.index]))
                        else:
                                tmpstart = 0
                        tmpstart = max([proc.mkspan, tmpstart])

                        if tmpstart < min_start:
                                min_start = tmpstart
                                bestproc = proc


                debug.print_debug("INFO", "Best is %d - min_start = %f" %(bestproc.index, min_start)            )
                return (bestproc, min_start)

        


        def traverse_graph(self, instructions):
                self.ready = []
                debug.print_debug("INFO", "Testing %s" %instructions)
                for (name, instr) in instructions.items():
                        if instr.n_inedges == 0:
                                self.ready += [instr]

                while len(self.ready) > 0:
                        #instr = random.choice(self.ready) #TODO: perhaps apply an heuristic to pick from the list
                        #instr = self.ready[0]
                        instr = max(self.ready, key = lambda i: i.priority)
                        #debug.print_debug("INFO", "Ready list %s" %[x.name for x in self.ready])
                        self.ready.remove(instr)
                        self.visit(instr)
                
                        dests = [(di, dp) for (si, sp, di, dp) in self.edges if si == instr]

                        for (dstinstr, dstport) in dests: 
                                dstinstr.n_inedges -= 1

                                if dstinstr.n_inedges == 0:
                                        debug.print_debug("INFO", "Adding %s to ready list" %dstinstr.name)
                                        self.ready += [dstinstr]
                        debug.print_debug("INFO", "Ready: %s" %[x.name for x in self.ready])


        def visit(self, instr):
                #place the nodec
                debug.print_debug("INFO", "Visiting %s" %instr.name)

                (instr.proc, instr.min_start) = self.choose_proc(instr)
                processor = instr.proc
                debug.print_debug("INFO", "Chosen proc is %d" %(instr.proc.index))
                #instr.min_start = processor.mkspan

                prob = instr.comp_prob(self)
                instr.min_end = processor.mkspan = instr.min_start + instr.avgtime

                debug.print_debug("INFO", "Min_start = %f Min_end = %f prob = %f" %(instr.min_start, instr.min_end, instr.comp_prob(self)))
                """the instr.comp_prob function also propagates the probability to the outgoing edges"""
                

        def build_graph(self, instrs, edges):
                edges_ref = []
                for edge in self.edges:
                        srcinstr = instrs[edge[0][0]]
                        srcport = edge[0][1]
                        dstinstr = instrs[edge[1][0]]
                        dstport = edge[1][1]
                                                         
                        edges_ref += [(srcinstr, srcport, dstinstr, dstport)]
                        dstinstr.n_inedges += 1

                #debug.print_debug("INFO", "%s %s" %(srcinstr.name, [x[1].name for x in srcinstr.dests]))
                self.edges = edges_ref #store the edges with reference to the InstNode objetcts, instead of the instruction names
                self.return_edges = []
                roots = [i for i in self.ordered_instructions if i.input_num == 0]

                self.tag_return_edges(self.edges, list(roots))
                self.build_super_graph(roots) 
                self.remove_loops(self.return_edges)
                
                for instr in roots:
                        self.set_priority(instr)


        def set_priority(self, instr):
                dests = [d for (s, s_p, d, d_p) in self.edges if s == instr]
                if not hasattr(instr, "priority"):

                        if len(dests) == 0:
                                instr.priority = instr.avgtime
                        else:
                                instr.priority = max([self.set_priority(d) for d in dests]) + instr.avgtime
                return instr.priority

        def tag_return_edges(self, edges, ready):
                #TODO: use vertex depths (distance from each root) to establish dependency between the inctag and the instruction from which the return edge comes.

                counters = dict([(inst, inst.input_num) for inst in self.ordered_instructions])
                marked_ports = []
                marked_instrs = []

                while len(ready) > 0:
                        instr = ready.pop()
                        outedges = [(s, s_p, d, d_p) for (s, s_p, d, d_p) in edges if s == instr]
                        for (srcinst, srcport, dstinst, dstport) in outedges:
                                if (dstinst, dstport) not in marked_ports:
                                        marked_ports += [(dstinst, dstport)]
                                        counters[dstinst] -= 1
                                        count = counters[dstinst]
                                        if count == 0:
                                                ready += [dstinst]
                                                marked_instrs += [dstinst]
                                                debug.print_debug("INFO", "Marking %s" %dstinst.name)
                                else:
                                
                                        if dstinst in marked_instrs and dstinst.op == "inctag":
                                                debug.print_debug("INFO", "Testing Path <%s, %s>" %(dstinst.name, srcinst.name))
                                                if  self.haspath(dstinst, srcinst, self.edges):
                                                        debug.print_debug("INFO", "Loop detected %s %s" %(srcinst.name, dstinst.name))
                                                        e = (srcinst, srcport, dstinst, dstport)
                                                        #self.edges.remove(e)
                                                        self.return_edges.append(e)
                                                        dstinst.n_inedges -= 1
                                

        
        def remove_loops(self,return_edges):
                for e in return_edges:
                        self.edges.remove(e)


                        
        def create_edges(self, dstname, dstport, source):
                edges = []
                
                sources = isinstance(source, list) and source or [source]
                for source in sources:
        
                        srcname = source.split('.')[0]
                        
                        if re.match(r".*\.[tf]$", source):
                                
                                srcport = source.split('.')[1]
                        else:
                                srcport = None #we only need to distinguish the ports of a steer
                        edges += [((srcname, srcport), (dstname, dstport))]

                return edges    
                        
                
                

        def asmline(self, tks):
                op = tks[0]
                if op == "steer": #TODO: maybe find a way to use the class hierarchy present in the flowasm.py assembler
                        debug.print_debug("INFO", "Instruction is Steer")
                        instr = SteerNode(tks, self.profile.avgtimes)
                else:
                        instr = InstNode(tks, self.profile.avgtimes)
                
                self.instructions[instr.name] = instr
                self.ordered_instructions += [instr]

                if instr.sources != None:
                        for destport, source in zip(range(len(instr.sources)), instr.sources):
                                self.edges += self.create_edges(instr.name, destport, source)



        def haspath(self, u, v, edges):
                """Check if there is a path between u and v."""
                #TODO: use memoization

                outedges = [(a, ap, b,bp) for (a, ap, b, bp) in edges if a == u]
                for (a, ap, b, bp) in outedges:
                        #debug.print_debug("INFO", "Testing: (%s, %s)" %(a, b))
                        if b == v:
                                debug.print_debug("INFO", "Found path: (%s,%s)" %(a,b))
                                return True
                        else:
                                edge = ((a, ap),(b,bp))
                                #debug.print_debug("INFO", flist(edges).remove(edge))
                                if self.haspath(b, v, flist(edges).remove(outedges)):
                                        return True
                return False




        def build_super_graph(self, roots):
                """Builds a graph that contains only the super-instructions. In this graph, and edge (u, v) exists if in the original graph there is a path between u and v such that there is no super-instruction in the path other than u and v."""
                self.superedges = set()
                self.supers = []
                self.stack_super_graph = []
                self.super_ret_edges = set()
                self.pending_superedges = set()
                self.pending_ret_edges = set()

                for instr in roots:
                        instr.inside_loop = False
                        if instr.is_super():
                                prev = instr
                        else:
                                prev = None
                        for dest in [di for (si, sp, di, dp) in self.edges if si == instr]:
                                self.traverse_supers(prev, dest)

                for (src, dest) in self.pending_superedges:
                        for destsuper in dest.nearest_supers:
                                print("later adding edge %s %s" %(src.name, destsuper.name))
                                self.superedges |= set([(src, destsuper)])
                        
                                if (src, dest) in self.pending_ret_edges and src.inside_loop:
                                        print("Adding pending %s %s" %(src.name, destsuper.name))
                                        self.super_ret_edges |= set([(src, destsuper)])

                print([instr.name for instr in self.supers])
                debug.start_debug("3")
                print([(a.name, b.name) for (a,b) in  self.superedges])
                print([(a.name, b.name) for (a,b) in  self.super_ret_edges])


        def traverse_supers(self, prev, instr, ret_edge_in_path=False, inctag_in_path=False):
                instr.nearest_supers = set()
                #nearest_supers stores all supers s such that there is a path <instr, s> where there are no other supers other than instr and s

                tmp_nearest_supers = set()
                self.stack_super_graph += [instr] #mark it as visited
        #       print "Visiting %s prev %s" %(instr.name, prev == None and "Empty" or prev.name)
                if instr.is_super():
                        if prev != None and (prev, instr):
                        #       print "Adding edge %s %s" %(prev.name, instr.name)
                                self.superedges |= set([(prev, instr)])
                                if ret_edge_in_path:
                                        self.super_ret_edges |= set([(prev, instr)])
                                        ret_edge_in_path = False
                        prev = instr
                        
                        self.supers += [instr]
                        instr.nearest_supers = set([instr])

                inctag_in_path |= instr.is_inctag()
                instr.inside_loop = inctag_in_path
                
                for dest in [di for (si, sp, di, dp) in self.edges if si == instr]:
                        if  [u for (u, up, v, vp)  in self.return_edges if u == instr and v == dest]:
                                """true if there is a return edge between instr and dest, notice that this will not work correctly in the (unlikely) cases where there is a normal edge AND a return edge between instr and dest"""
                                print("%s is a return edge." %([instr.name, dest.name]))
                                is_ret_edge = True
                        else:
                                is_ret_edge = ret_edge_in_path

                        if dest not in self.stack_super_graph: 
                                tmp_nearest_supers |= self.traverse_supers(prev, dest, is_ret_edge, inctag_in_path)
        
                        else:
                                #dest still in the stack, we add this to pending edges to resolve the dependencies at the end
                                if prev != None or instr.is_super():
                                        self.pending_superedges |= set([(prev, dest)])
                                        if ret_edge_in_path:
                                                self.pending_ret_edges |= set([(prev, dest)])
                


                

                if len(instr.nearest_supers) == 0: #if instr is not a super, we backpropagate the nearest supers of the targets
                #       print "%s is not a super" %instr
                        instr.nearest_supers = tmp_nearest_supers
        
                self.stack_super_graph.pop()
                return instr.nearest_supers

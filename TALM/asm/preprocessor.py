# FlowASM - A Trebuchet assembler for TALM's dataflow graphs.
# Authors - Tiago A.O.A. <tiagoaoa@cos.ufrj.br> Leandro J. Marzulo <lmarzulo@cos.ufrj.br>
#
# THIS IS NOT AN OFFICIAL RELEASE
# DO NOT COPY OR DISTRIBUTE
#


import re
import debug
import os #just to get environment variables
class Profile:
        def __init__(self):
                self.avgtimes = {}
                self.varprobs = {}


class PreProc:
        def __init__(self):
                self.replaces=[]
                self.functioncalls = {} #number of callgroups targeting each function
                self.superinsts = {} #the blocknumber of each superinstruction referenced by a superinst() macro

                self.replaces += [(r"\.g", ".0")] #go-ahead token is the output #0
                self.replaces += [(r"\.w", ".1")] #wait token is the output #1
                #self.replaces +=[("(\w+)\${(\w+)\.\.(\w+)}(\.\w+)*", self.taskrange)]
                self.replaces += [(r"([^\s,]+)\${([^}]+)\.\.([^}]+)}(\..)?", self.taskrange)] # macro for declaring a range of source operands
                #taskrage must come BEFORE taskmacro
                self.replaces += [(r"({(\w)+=(.*?)\.\.(.*?)}).*", self.taskmacro)] #macro for declaring multiple instructions for multiple tasks
                self.current_placement = 0
                self.placement_mode = "STATIC"
                self.profile = Profile()
                
                


        def replacemacros(self, line):
                for repl in self.replaces:
                        expression = repl[0]
                        substitution = repl[1]
                        line = re.sub(expression, substitution, line)
                return line


        def testemacro(self, nome):
                self.replaces += [(nome, "lalalala")]

        def callgroup(self, groupname, funcname):
                """The call group macro.
                If the target function, the callee, has already been pointed to by another callgroup
                we just increment its counter and use the incremented counter as the tag of the call group.
                Otherwise, we have to initialize the counter, i.e. put it in self.functions"""
                if funcname not in self.functioncalls: 
                        self.functioncalls[funcname] = -1

                self.functioncalls[funcname] += 1
                self.replaces += [(groupname, str(self.functioncalls[funcname]))]


                #print self.replaces

        def placeinpe(self, penum, mode=None):
                print("Changing placement to %d" %penum)
                self.current_placement = eval(str(penum))
                if mode != None:
                        self.placement_mode = mode

        def superinst(self, instname, blocknumber, resnum, isspec, has_immed=False):
                """The super instruction macro. Paramenters are:
                        instname: the label given for this instruction on the code.
                        blocknumber: the number of the block in C.
                        resnum: number of output operands generated.
                        isspec: Boolean, True if the instruction is speculative."""
                
                if has_immed:
                        opcode = isspec and "specsuperi" or "superi" 
                else:
                        opcode = isspec and "specsuper" or "super" 

        
                expression = r"(\s*)" + instname + r"\s+(\w+)(.*)"
                self.replaces += [(expression, "\\1%s \\2, %d, %d\\3" %(opcode, blocknumber, resnum) )]

                self.superinsts[instname] = blocknumber
        

        def defconst(self, constname, value):
                """put the new macro at the top of the preprocessor chain."""
                self.replaces = [(constname, value)] + self.replaces 



        def evalexp(self, match):
                #print "eval %s" %match.group(1)
                return str(eval(match.group(1)))
       

        def taskmacro(self, match):
                """Macro used for declaring multiple instances of a instruction, to be placed across multiple PEs. 
                Example: {i=1..3} task tsk${i}, tid${i}, order${i-1}
                Will produce:   task tsk1, tid1, order0
                                task tsk2, tid2, order1
                                task tsk3, tid3, order2
                """
                output = ""
                line = match.group(0)
                var = match.group(2)     #index variable used for the interval (i in the example above)
                a = eval(match.group(3)) #beginning of the interval (1 in the example above)
                b = eval(match.group(4)) #end of the interval (3 in the example above)
                line = line.replace(match.group(1), '') #remove the {i=a..b} part
                for i in range(a,b+1):
                        output += re.sub(r"(\W)%s(\W)" %var, "\\1 %d \\2" %i, line) + "\n"
                        #substitute occurances of the variable by the value (0, 1, 2, 3..)

                output = re.sub(r"\${(.*?)}", self.evalexp, output) #evaluate the expressions using the index var.
                return output
       
        def taskrange(self, match): 
                """Macro used to declare a range of source operands.
                Example: gather gth, tsk${0..3}
                Will produce: gather gth, tsk0, tsk1, tsk2, tsk3
                """
                debug.start_debug("PRE")
                name = match.group(1)
                a = eval(match.group(2))
                b = eval(match.group(3))
                suffix = match.group(4)
                if suffix == None: suffix = ""
                output = ""
                for i in range(a,b+1):
                        separator = i < b and ", " or ""
                        output += name + str(i) + suffix + separator
                print(output)
                return output
        def setntasks(self, n):
                self.number_of_tasks = n
                self.replaces = [("NUM_TASKS", str(n))] + self.replaces #add this macro to the first position of the macro chain

        def varprob(self, var, prob):
                if  0 < float(prob) < 1:
                        self.profile.varprobs[var] = prob
                else:
                        print("Error: Probability for %s == 1 is not in the interval ]0;1[" % var)
        def avgtime(self, name, time):
                blocknumer = None
                if name in self.superinsts:
                        blocknumber = self.superinsts[name]
                else:
                        print("Error: no superinstruction %s was created with a superinst() macro" %name)

                        return None

                if 0 < int(time):
                        self.profile.avgtimes[blocknumber] = int(time)
                else:
                        print("Error: Average time for %s is not an integer bigger than 0" % name)

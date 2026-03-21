# FlowASM - A Trebuchet assembler for TALM's dataflow graphs.
# Authors - Tiago A.O.A. <tiagoaoa@cos.ufrj.br> Leandro J. Marzulo <lmarzulo@cos.ufrj.br>
#
# THIS IS NOT AN OFFICIAL RELEASE
# DO NOT COPY OR DISTRIBUTE
#



import debug
import struct
import re
from preprocessor import PreProc

SIZE_OF_SRC_LEN = 5 #number of bits used to represent the number of sources in the instruction opcode bitmap
SIZE_OF_DST_LEN = 5
SIZE_OF_SRC_OFFSET = 5
def SIZEOF(format):
        return struct.calcsize(format)
INSTRSET = {
"const":        0,
"fconst":       0, #fconst and const can have the same opcode
"dconst":       1,
"addi":         2,
"subi":         3,
"fmuli":        4,
"muli":         5,
"divi":         6,
"inctagi":      7,
"lthani":       8,
"gthani":       9,
"callsnd":      10,
"retsnd":       11,
"inctag":       12,
"add":          13,
"sub":          14,
"mul":          15,
"div":          16,
"fadd":         17,
"dadd":         18,
"band":         19,
"steer":        20,
"lthan":        21,
"gthan":        22,
"equal":        23,
"ret":          24,
"cphtodev":     25,
"cpdevtoh":     26,
"commit":       27,
"stopspec":     28,
"tagval":       29,
"valtag":       30,
"super":        31,
"superi":       31, #super and superi have the same opcode, super's immed is set to 0   
"specsuper":    31 | (1 << (SIZEOF('i')*8 - SIZE_OF_SRC_LEN - SIZE_OF_DST_LEN - 1)),
"specsuperi":   31 | (1 << (SIZEOF('i')*8 - SIZE_OF_SRC_LEN - SIZE_OF_DST_LEN - 1)) #speculative instructions have the most significant bit of the opcode part set to 1.
}
                

def writetofile(format, l, file):
        #file.write(struct.pack(format, *l))
        
        #print format
        #print l
        for i in l:
                #print "Escrevendo %s" %i

                file.write(struct.pack(format, i))


class Instruction:
        def __init__(self):
                pass
class IntIns:
        def tonum(self, tk):
                #return int(tk, 0)
                return int(eval(tk))

        def getimmedtype(self):
                return('i')     #for the struct.pack mask

class FloatIns:
        def tonum(self, tk):
                return float(eval(tk))


        def getimmedtype(self):
                return('f')

class TwoOutPorts: #instructions with two output ports (right now only the steer inherits from this class)
        def getnoutputs(self):
                return 2

class ALU(Instruction):
        def __init__(self, tks, assembler):

#               self.name = tks[1]
                self.src1 = assembler.getsources(tks[2])
                self.src2 = assembler.getsources(tks[3])
                
                noutputs = self.getnoutputs()
                self.code = assembler.create_opmask(INSTRSET[tks[0]], 2, noutputs) #create the opmask indicating that the instruction has two source operands.

                #writetofile("iii", [self.code, self.src1, self.src2], assembler.output)
                writetofile("I", [self.code] + [len(self.src1)] + self.src1 + [len(self.src2)] + self.src2, assembler.output)
        def getnoutputs(self): #returns the number of outputs the instruction generates (defaulted to 1)
                return 1

class ALUi(Instruction):
        def __init__(self, tks, assembler):
                self.src = assembler.getsources(tks[2])
                noutputs = self.getnoutputs()
                #self.code = assembler.create_opmask(INSTRSET[tks[0]], len(self.src))
                
                self.code = assembler.create_opmask(INSTRSET[tks[0]], 1, noutputs) #create the opmask indicating that the instruction has one source operand(the other is the immediate)

                self.immed = self.tonum(tks[3])
                

                itype = self.getimmedtype()
        #       writetofile("ii%c"%itype, [self.code, self.immed, self.src], assembler.output)
                writetofile("I", [self.code], assembler.output)
                writetofile("%c"%itype, [self.immed], assembler.output) 
                writetofile("I", [len(self.src)] + self.src, assembler.output)
        def getnoutputs(self):
                return 1
class Const(Instruction):
        def __init__(self, tks, assembler):
                self.code = assembler.create_opmask(INSTRSET[tks[0]], 0)
#               self.name = tks[1]
                self.immed = self.tonum(tks[2]) #to int or float
                
                itype = self.getimmedtype()
                debug.start_debug("1")
                #writetofile("i%c"%itype, [self.code, self.immed], assembler.output)
                writetofile("I", [self.code], assembler.output)
                writetofile("%c"%itype, [self.immed], assembler.output)
class OneOper(Instruction):
        def __init__(self, tks, assembler):
                self.src = assembler.getsources(tks[2])
                self.code = assembler.create_opmask(INSTRSET[tks[0]], 1)
                writetofile("I", [self.code] + [len(self.src)] + self.src, assembler.output)

class CommitInst(Instruction):
        def __init__(self, tks, assembler):
                self.name = tks[1]
                self.outputcount = 2 #the commit has two different outputs (speculation number and the go-ahead)
                srclist = []
                for src in tks[2:]:
                        srclist += [assembler.getsources(src)]
                self.code = assembler.create_opmask(INSTRSET[tks[0]], len(srclist), self.outputcount)

                writetofile("I", [self.code], assembler.output)
                for src in srclist:
                        writetofile("I", [len(src)] + src, assembler.output)

class SuperInst(Instruction):
        def __init__(self, tks, assembler):
                self.name = tks[1]
                #self.instcount = 0
                self.outputcount = int(tks[3])
                srclist = []
                self.supernumber = int(tks[2]) #the number of the corresponding super instruction
                #outputlist = isinstance(tks[2], list) and tks[2] or [tks[2]]
                #for inst in outputlist:
                #       assembler.addtosuper(self.name, inst, self.instcount)
                #       self.instcount += 1
                for src in self.proc_srclist(tks):
                        srclist += [assembler.getsources(src)] #a super instruction has multiple source operands(src1, src2, src3...) and each can come from multiple instructions. See examples.
                        
                self.code = assembler.create_opmask(INSTRSET[tks[0]] + self.supernumber, len(srclist), self.outputcount)

                writetofile("I", [self.code], assembler.output)

                writetofile("I", [self.immed], assembler.output) 
                
                for src in srclist: 
                        writetofile("I", [len(src)] + src, assembler.output)
        def proc_srclist(self, tks):
                self.immed = 0
                return tks[4:]

        
class SuperInstImmed(SuperInst):
        def proc_srclist(self, tks):
                self.immed = int(tks[-1]) #last token is the immediate operand, which is used as task id.
                return tks[4:-1]


class GPUCopyInst(Instruction):
        def __init__(self, tks, assembler):
                self.name = tks[1]
                self.size = assembler.getsources(tks[2])
                self.destop = assembler.getsources(tks[3])
                self.srcop = assembler.getsources(tks[4])

                self.code = assembler.create_opmask(INSTRSET[tks[0]], 3)

                #if len(tks) > 5:
                #       self.immed = int(tks[-1])
                writetofile("I", [self.code], assembler.output)
                writetofile("I", [len(self.size)] + self.size + [len(self.destop)] + self.destop + [len(self.srcop)] + self.srcop, assembler.output)


class add(ALU,IntIns):
        pass

class sub(ALU,IntIns):
        pass
class mul(ALU, IntIns):
        pass

class div(TwoOutPorts, ALU):
        pass
class muli(ALUi, IntIns):
        pass
class fmuli(ALUi, FloatIns):
        pass 
class divi(TwoOutPorts, ALUi, IntIns):
        pass
class addi(ALUi,IntIns):
        pass

class subi(ALUi, IntIns):
        pass
class const(Const, IntIns):
        pass

class fconst(Const, FloatIns):
        pass
class dconst(Const, FloatIns):
        pass
class fadd(ALU, FloatIns):
        pass
class dadd(ALU, FloatIns):
        pass
class band(ALU, IntIns):
        pass
class steer(TwoOutPorts, ALU, IntIns):
        pass
class lthan(ALU, IntIns):
        pass
class lthani(ALUi, IntIns):
        pass
class gthan(ALU, IntIns):
        pass
class gthani(ALUi, IntIns):
        pass
class equal(ALU):
        pass
class inctag(OneOper):
        pass
class inctagi(ALUi, IntIns):
        pass

class super(SuperInst):
        pass
class specsuper(SuperInst):
        pass
class superi(SuperInstImmed):
        pass
class specsuperi(SuperInstImmed):
        pass
class callsnd(ALUi, IntIns):
        pass
class retsnd(ALUi, IntIns):
        pass
class ret(ALU, IntIns):
        pass
class tagval(OneOper):
        pass
class valtag(ALU, IntIns):
        pass

class cpdevtoh(GPUCopyInst):
        pass
class cphtodev(GPUCopyInst):
        pass

class commit(CommitInst):
        pass

class stopspec(CommitInst):
        pass


class FlowAsm:
        def __init__(self): 
                self.names = {}
                self.instructions = []
                self.instcount = 0
        def getsources(self, name):
                if isinstance(name, list):
                        #print "aaa %s" %name
                        output = []
                        for source in name:
                                if isinstance(source, list):
                                        #we may have a list inside a list, in the case of function operands (e.g. function_name[1] is converted to [sourceinst0, sourceinst1,..])
                                        output += [self.create_srcmask(n) for n in source]
                                else:
                                        output += [self.create_srcmask(source)]

                        return output #return [self.create_srcmask(n) for n in name]
                else:
                        return [self.create_srcmask(name)] #TODO: fazer isso direito
        
        def evaltoken(self, token):
                #rint "tokenn %s" %token
                #f re.match("\w+\[\w+\]", token):
                #obj = eval("self." + token)
                #lse:
                return eval(token)


        def asmline(self, tks):
                instr = eval(tks[0] + '(tks, self)') #run the creator mnemonic(tks, self)
                self.instructions += [instr]    
        def addname(self, name):
                if re.match(r"(\w+)\[\w*\]", name):
                        (funcname, key) = re.match(r"(\w+)\[(\w*)\]", name).groups()
                        key = int(key)
                        if not hasattr(self, funcname): #TODO: Do it properly!
                                exec("self.%s = {}" %funcname)

                                #print "created dict %s %s" %(funcname, key)
                        d = eval("self.%s" %funcname)
                        
                        debug.print_debug("INFO", "adding instruction %d to %s %s %s" %(self.instcount, d, funcname, key))
                        if key not in d:
                                d[key] = []
                        name = "instruction_%d" %(self.instcount) 
                        d[key] += [name]
                        #this indirection (going to self.names for the value of "instruction_x") could be avoided, since we know the value is 'x' itself. perhaps this shall be done in the future. 
                else:

                        if name in self.names:
                                print("Error: instruction name (%s) already exists" %name)
                                exit(1)
                self.names[name] = self.instcount #associate a number with the signal name
                        #self.names[name] = (self.instcount, 0)
                self.instcount += 1

        
        def start(self): #write the numer of instructions to the output file's header
                writetofile("I", [self.instcount], self.output)
        def exit(self):
                self.output.close()
        
        #def create_opmask2(self, op, len1, len2=None):
                                
        #       mask = op | ( len1 << (SIZEOF('i')*8 -1 -(SIZE_OF_SRC_LEN -1)) ) 
                        #sets the SIZE_OF_SRC_LEN most significant bits with len1               
        #       if len2:
        #               mask |=  len2 << (SIZEOF('i')*8 -1 -(2*SIZE_OF_SRC_LEN -1) )
        #       return mask

        def create_opmask(self, op, n_src, n_dst=1):
                mask = op | (n_dst << (SIZEOF('i')*8 -1 -(SIZE_OF_DST_LEN -1)) )
                mask |= n_src << (SIZEOF('i')*8 -1 -(2*SIZE_OF_SRC_LEN -1))
                
                return mask


        def create_srcmask(self, name):
                if name.find('.') > 0: #TODO: Verify if the source has more than one port(i.e. is a steer or a ret)
                        sourceport = name.split('.')[1]         
                        if sourceport == 't' or sourceport == 'f':
                        #       mask = (sourceport == 't' and 1 or 0) << (SIZEOF('i')*8 -1) #set the most significant bit it the source is the TruePort of a Steer instruction (ex: st1.t where st1 is a steer).
                        #       src_offset = 0
                                sourceport = (sourceport == 't' and 1 or 0)
                        #else:
                        #mask = 0
                        src_offset = int(sourceport)

                        name = name.split('.')[0]
                else: 
                        #mask = 0
                        #src_offset = self.names[name][1]
                        src_offset = 0

                #mask |= self.names[name][0] << SIZE_OF_SRC_OFFSET | src_offset
                mask = self.names[name] << SIZE_OF_SRC_OFFSET | src_offset
        

                return mask

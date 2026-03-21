# FlowASM - A Trebuchet assembler for TALM's dataflow graphs.
# Authors - Tiago A.O.A. <tiagoaoa@cos.ufrj.br> Leandro J. Marzulo <lmarzulo@cos.ufrj.br>
#
# THIS IS NOT AN OFFICIAL RELEASE
# DO NOT COPY OR DISTRIBUTE
#



import sys
import pdb
import os
import re
import flowasm
import graphvizgen
import scheduler
import debug
from optparse import OptionParser

def addquotes(match):
	token = match.group(0)

	if re.match(r"\w+\[[0-9]+\]", token):
		token = "self." + match.group(0)
	else:
		#We shall not add quotes to the representations of function operands. They are solved on their on.
		token = '"' + match.group(0) + '"'
	
	return token

preprocessor = flowasm.PreProc()
assembler = flowasm.FlowAsm()



asmers = [assembler]

optionparser = OptionParser()
optionparser.add_option("-n", "--ntasks", dest="num_tasks", help="Define number of parallel tasks for the preprocessor.")
optionparser.add_option("-o", "--output", dest="outfilename", help="The name of the .flb (binary) and .pla (placement) files generated. You must not specify the extension.")

optionparser.add_option("-a", "--autoplace", action="store_true", dest="autoplace", help="Enable automatic placement.")

#optionparser.add_option("-p", "--profile", dest="proffilename", help="The name of the file containing boolean conditions and super-instructions avg time profiling information.")


options, args = optionparser.parse_args()

file = open(args[0], "r")
output = open(options.outfilename + ".flb", "wb")

placefile = open(options.outfilename + ".pla", "w")
placement = []


if options.num_tasks != None:
	print("Number of tasks: %d" %int(options.num_tasks))
	preprocessor.setntasks(int(options.num_tasks))


if options.autoplace != None:
	print("Autoplacement enabled.")
	placer = scheduler.GraphBuilder(int(options.num_tasks))
	placer.profile = preprocessor.profile
	placer.outfile = open(options.outfilename + "_auto.pla", "w")
	asmers += [placer]


#if options.proffilename != None:
#	placer.prof_file = open(options.proffilename, "r")
#else:
#	placer.prof_file = None

#if (len(args) > 2):
#	print args[2]
#	graphvizoutput = open(args[2], "w")
#	asmers +=  [graphvizgen.graphgen(graphvizoutput)]

preprocessed_data = []
assembler.output = output

for line in file:
		line = re.sub("//.*", "", line) #remove comments
		debug.print_debug("INFO", "Original line: " + line.replace('\n', ''))
		if line.strip(): 
			if re.search(r"\w+\(.*\)", line):
				eval("preprocessor." + line.strip())  #evaluate macros
			else:

				line = preprocessor.replacemacros(line) 
				proclines = line.strip().split('\n')
				#print proclines
				
				"""If the preprocessor generated multiple instructions and the placement
				mode is DYNAMIC, they will each be placed in different PEs, starting from PE
				preprocessor.current_placement, which is selected with the macro placeinpe(n)"""

				tmpplacement = preprocessor.current_placement
				for pline in proclines:
					debug.print_debug("INFO", "Preprocessed line: " + pline)
					name = re.search(r"\w+\s+((\w+\[[0-9]+\]|\w+)),", pline).group(1) 

					preprocessed_data += [pline.strip()]
				
					#print "Add name %s" %name 

					assembler.addname(name)

					placement += [tmpplacement]
					if preprocessor.placement_mode == "DYNAMIC":
						tmpplacement += 1 
			
			


file.close()

#graphgen.init()

debug.print_debug("INFO", "Finished preprocessing stage.")
#print  preprocessed_data
for asm in asmers:
	asm.start()

operands_regexp = r"([+-]*([0-9]*\.[0-9]+|[0-9]+)[-+*/]*)|\w+\.\w+|(\w+\[[0-9]+\]|\w+)" 
"""Regular expression intended to find:
	- Constants, such as +0.22, -1, 10 etc
	- Instruction names
	- Operand names, such as srcinst, srcinst.0 or srcinst.t
	- Function operands, such as fctn[1]"""
#TODO: Document the regexp better

#from flowasm import funcao
print(dir(flowasm))
for line in preprocessed_data:
	tks = [re.split(r"\s", line)[0]]
	startopers = re.search(r'\s', line).start() + 1
	#print tks
	tks += [tk for tk in assembler.evaltoken(re.sub(operands_regexp, addquotes, line[startopers:]))]
	
	#use python parser to compute the operands, so we have to add quotes to the names to make
	#them strings

	#print "Assembling %s" %tks

	debug.print_debug("INFO", "Assembling %s" %tks)	
	
	for asm in asmers:
		asm.asmline(tks)
	#assembler.asmline(tks)
	
	#if graphgen:
	#	graphgen.asmline(tks)

debug.start_debug("2")

#output.close()
for asm in asmers:
	asm.exit()


#Write the placement file
placefile.write("%d\n" %len(placement))
for inst in placement:
	placefile.write("%d\n" %inst)
placefile.close()



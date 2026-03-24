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

import pdb
import os
def start_debug(n):
	if "DEBUG" in os.environ and os.environ["DEBUG"] == n:
		pdb.set_trace()
def print_debug(level, msg):
	if "DEBUG_MSG" in os.environ and os.environ["DEBUG_MSG"] == level:
		print("[%s] %s" %(level, msg))

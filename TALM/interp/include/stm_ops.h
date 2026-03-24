/*
 * TALM/Trebuchet — Architecture and Language for Multi-threading
 *
 * Copyright (C) 2010-2026  Tiago A.O. Alves <tiago@ime.uerj.br>
 *                           Leandro Marzulo <lmarzulo@cos.ufrj.br>
 *
 * This file is part of TALM.
 *
 * TALM is free software: you can redistribute it and/or modify it
 * under the terms of the GNU Lesser General Public License as
 * published by the Free Software Foundation, either version 3 of
 * the License, or (at your option) any later version.
 *
 * TALM is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with TALM. If not, see <https://www.gnu.org/licenses/>.
 */

#define LOAD(addr)                      tm_load32(tx, (tm_word32 *)addr)
//#define LOADD(addr)			tm_load_double(tx, (double *)addr)
#define LOADD(addr)			(double)tm_load64(tx, (tm_word64 *)addr)
#define LOAD64(addr)			tm_load64(tx, (tm_word64 *)addr)
#define STORE(addr, value)              tm_store32(tx, (tm_word32 *)addr, (tm_word32)value)
//#define STORED(addr, value)		tm_store_double(tx, (double *)addr, value)
#define STORED(addr, value)		tm_store64(tx, (tm_word64 *)addr, (tm_word64)value)
#define STORE32(addr, value)		tm_store32(tx, (int *)addr, (int)value)
#define STORE64(addr, value)		tm_store64(tx, (tm_word64 *)addr, (tm_word64)value)

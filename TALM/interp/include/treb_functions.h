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

#include <sys/time.h>
#include <time.h>
#include <sys/timeb.h>
#include <stdlib.h>
#include <stdio.h>

#define TIME_s 0
#define TIME_ms 1
#define TIME_us 2
#define TIME_ns 3

int treb_get_n_procs();

int treb_get_n_tasks();

int treb_get_tid();

double treb_get_time(int resolution);

char * treb_get_arg(int argnum);

int treb_get_n_args();

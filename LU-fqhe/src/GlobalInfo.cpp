/*
 *  Copyright 2013 William J. Brouwer, Pierre-Yves Taunay
 *
 *  Licensed under the Apache License, Version 2.0 (the "License");
 *  you may not use this file except in compliance with the License.
 *  You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 *  Unless required by applicable law or agreed to in writing, software
 *  distributed under the License is distributed on an "AS IS" BASIS,
 *  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 *  See the License for the specific language governing permissions and
 *  limitations under the License.
 */


#include <iostream>
#include <stdexcept>
#include <mpi.h>

#include "GlobalInfo.h"

using namespace std;

// Constructors
GlobalInfo::GlobalInfo(){
	this->discover();
}

GlobalInfo::GlobalInfo(int nodCnt) {
	setNodCnt(nodCnt);
}

// Getter
int GlobalInfo::getNodCnt() {
	return nodCnt;
}

// Setter
void GlobalInfo::setNodCnt(int nodCnt) {
	this->nodCnt = nodCnt;
}

// Discovering the number of nodes
void GlobalInfo::discover() {
	try {
		nodCnt = MPI::COMM_WORLD.Get_size();
		int rank = MPI::COMM_WORLD.Get_rank();
#ifdef __VERBOSE__
		cout << "INFO \t Node " << rank << "\t Found " << nodCnt << " node(s) available" << endl;
#endif
	}
	catch(MPI::Exception& e) {
		throw exception();
	}
}

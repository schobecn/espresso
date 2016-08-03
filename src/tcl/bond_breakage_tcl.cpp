/*
  Copyright (C) 2011,2012,2013,2014,2015,2016 The ESPResSo project
  
  This file is part of ESPResSo.
  
  ESPResSo is free software: you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation, either version 3 of the License, or
  (at your option) any later version.
  
  ESPResSo is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details.
  
  You should have received a copy of the GNU General Public License
  along with this program.  If not, see <http://www.gnu.org/licenses/>. 
*/
#include "parser.hpp" 
#include "bond_breakage.hpp"


int tclcommand_bond_breakage(ClientData data, Tcl_Interp *interp, int argc, char **argv) 
{
  // If no argumens are given, print status
  if (argc==1) {
    if (bond_breakage().handlers.size()==0)
    {
      Tcl_AppendResult(interp, "off", (char*) NULL);
    }
    else
    {
      // Find names for active handles
      bool first=true;
      for (auto hn : bond_breakage().active_handlers_by_name()) {
        if (first)
          first=false;
        else
          Tcl_AppendResult(interp, " ", (char*) NULL);
        Tcl_AppendResult(interp, hn.c_str(), (char*) NULL);
      }
    }
    return TCL_OK;
  }
  if (ARG_IS_S_EXACT(1,"available_handlers")) {
      bool first=true;
      for (auto hn : available_bond_breakage_handlers_by_name()) {
        if (first)
          first=false;
        else
          Tcl_AppendResult(interp, " ", (char*) NULL);
        Tcl_AppendResult(interp, hn.c_str(), (char*) NULL);
      }
      return TCL_OK;
  }
  else
  if (ARG_IS_S_EXACT(1,"off")) {
    bond_breakage().handlers.clear();
  }
  else
  if (ARG_IS_S_EXACT(1,"add")) {
    // Arguments are names of breakage handlers. Iterate over them and add the hanlder
    argc-=2;
    argv+=2;
    while (argc>0) {
        if (! bond_breakage().add_handler_by_name(std::string(argv[0]))) {
          Tcl_AppendResult(interp, "Unknown handler name ", (char*) NULL);
          Tcl_AppendResult(interp, argv[0], (char*) NULL);
          return TCL_ERROR;
        }
        // Go to next argument
        argv++;
        argc--;
    }

  }
  else {
    Tcl_AppendResult(interp, "Unknown command:", (char*) NULL);
    Tcl_AppendResult(interp, argv[1], (char*) NULL);
    return TCL_ERROR;
  }
  return TCL_OK;
}


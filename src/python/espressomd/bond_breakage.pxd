from libcpp cimport bool
from libcpp.string cimport string
from libcpp.vector cimport vector

ctypedef void(*BreakageHandler)(int,int,int)
cdef extern from "bond_breakage.hpp":
    cdef cppclass _BondBreakage "BondBreakage":
        vector[BreakageHandler] handlers
        bool add_handler_by_name(string & n)
        const vector[string] active_handlers_by_name()

    _BondBreakage& bond_breakage()

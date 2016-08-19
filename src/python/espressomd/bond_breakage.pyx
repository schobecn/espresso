cdef class BondBreakage:
    cdef _BondBreakage* bb

    def __cinit__(self):
        self.bb = &bond_breakage()

    def active_handlers(self):
        return self.bb.active_handlers_by_name()

    def clear_handlers(self):
        self.bb.handlers.clear()

    def add_handler(self, name):
        self.bb.add_handler_by_name(name)

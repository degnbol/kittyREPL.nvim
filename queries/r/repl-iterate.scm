; Loop bindings and assignments, for deriving a single iteration of a loop.
(for_statement variable: (_) @variable sequence: (_) @iterable)
(binary_operator lhs: (_) @assign.variable operator: _ @op
                 rhs: (_) @assign.iterable
  (#any-of? @op "<-" "<<-" "="))

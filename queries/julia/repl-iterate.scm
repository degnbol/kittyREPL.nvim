; Loop bindings and assignments, for deriving a single iteration of a loop.
(for_binding (_) @variable . (operator) . (_) @iterable)
(assignment (_) @assign.variable . (operator) @op . (_) @assign.iterable
  (#eq? @op "="))

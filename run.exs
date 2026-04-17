Mix.start()

Mix.Project.in_project(:simple_tableaux_solver, __DIR__, fn _project_module ->
  Mix.Task.run("loadpaths")
  Mix.Task.run("sts.solve", System.argv())
end)

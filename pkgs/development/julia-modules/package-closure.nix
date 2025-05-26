{ lib
, julia
, python3
, runCommand

, augmentedRegistry
, packageNames
, packageOverrides
, packageImplications
}:

let 
  # The specific package resolution code depends on the Julia version
  # These are pretty similar and could be combined to reduce duplication
  resolveCode = if lib.versionOlder julia.version "1.7" then resolveCode1_6 else resolveCode1_8;

  resolveCode1_6 = ''
    import Pkg.API: check_package_name
    import Pkg.Types: Context!, PRESERVE_NONE, manifest_info, project_deps_resolve!, registry_resolve!, stdlib_resolve!, ensure_resolved
    import Pkg.Operations: _resolve, assert_can_add, is_dep, update_package_add

    foreach(pkg -> check_package_name(pkg.name, :add), pkgs)
    pkgs = deepcopy(pkgs)  # deepcopy for avoid mutating PackageSpec members
    Context!(ctx)

    project_deps_resolve!(ctx, pkgs)
    registry_resolve!(ctx, pkgs)
    stdlib_resolve!(pkgs)
    ensure_resolved(ctx, pkgs, registry=true)

    assert_can_add(ctx, pkgs)

    for (i, pkg) in pairs(pkgs)
        entry = manifest_info(ctx, pkg.uuid)
        pkgs[i] = update_package_add(ctx, pkg, entry, is_dep(ctx, pkg))
    end

    foreach(pkg -> ctx.env.project.deps[pkg.name] = pkg.uuid, pkgs)

    pkgs, deps_map = _resolve(ctx, pkgs, PRESERVE_NONE)
'';

resolveCode1_8 = ''
    import Pkg.API: handle_package_input!
    import Pkg.Types: PRESERVE_NONE, project_deps_resolve!, registry_resolve!, stdlib_resolve!, ensure_resolved
    import Pkg.Operations: _resolve, assert_can_add, update_package_add

    foreach(handle_package_input!, pkgs)

    # The handle_package_input! call above clears pkg.path, so we have to apply package overrides after
    overrides = Dict{String, String}(${builtins.concatStringsSep ", " (lib.mapAttrsToList (name: path: ''"${name}" => "${path}"'') packageOverrides)})
    println("Package overrides: ")
    println(overrides)
    for pkg in pkgs
      if pkg.name in keys(overrides)
        pkg.path = overrides[pkg.name]
      end
    end

    project_deps_resolve!(ctx.env, pkgs)
    registry_resolve!(ctx.registries, pkgs)
    stdlib_resolve!(pkgs)
    ensure_resolved(ctx, ctx.env.manifest, pkgs, registry=true)

    assert_can_add(ctx, pkgs)

    for (i, pkg) in pairs(pkgs)
        entry = Pkg.Types.manifest_info(ctx.env.manifest, pkg.uuid)
        is_dep = any(uuid -> uuid == pkg.uuid, [uuid for (name, uuid) in ctx.env.project.deps])
        # Handle different Julia versions
        if VERSION >= v"1.11"
            pkgs[i] = update_package_add(ctx, pkg, entry, false, false, is_dep)
        else
            pkgs[i] = update_package_add(ctx, pkg, entry, is_dep)
        end
    end

    foreach(pkg -> ctx.env.project.deps[pkg.name] = pkg.uuid, pkgs)

    # Save the original pkgs
    orig_pkgs = pkgs
    orig_pkg_names = Set([pkg.name for pkg in orig_pkgs])

    if VERSION >= VersionNumber("1.9")
        # Blacklist of packages to exclude (development tools that cause conflicts)
        blacklisted = Set([
            "Atom", "FlameGraphs", "BenchmarkTools", "ProfileView", "Juno",
            "TracyProfiler_jll", "Cthulhu", "Debugger", "Revise", "ProfileCanvas",
            "ProfileSVG", "PProf", "JuliaInterpreter"
        ])
        
        # Pass 1: Initial resolution
        pkgs, deps_map = _resolve(ctx.io, ctx.env, ctx.registries, pkgs, PRESERVE_NONE, ctx.julia_version)
        
        # Collect weak dependencies from pass 1
        resolved_uuids = Set([pkg.uuid for pkg in pkgs])
        weak_deps_names = Set{String}()
        
        for (pkg_uuid, deps) in pairs(deps_map)
            for (dep_name, dep_uuid) in pairs(deps)
                if !(dep_uuid in resolved_uuids) && !(dep_name in blacklisted)
                    push!(weak_deps_names, dep_name)
                end
            end
        end
        
        if !isempty(weak_deps_names)
            println("Found weak dependencies from pass 1: $weak_deps_names")
            
            # Pass 2: Add weak dependencies and resolve again
            all_package_names = Set{String}(pkg.name for pkg in orig_pkgs)
            union!(all_package_names, weak_deps_names)
            
            # Filter out blacklisted packages
            all_package_names = setdiff(all_package_names, blacklisted)
            
            # Create fresh specs for all packages
            all_pkgs = [PackageSpec(name) for name in all_package_names]
            
            # Reset and resolve everything together
            empty!(ctx.env.project.deps)
            
            # Apply overrides
            for pkg in all_pkgs
                if pkg.name in keys(overrides)
                    pkg.path = overrides[pkg.name]
                end
            end
            
            project_deps_resolve!(ctx.env, all_pkgs)
            registry_resolve!(ctx.registries, all_pkgs)
            stdlib_resolve!(all_pkgs)
            ensure_resolved(ctx, ctx.env.manifest, all_pkgs, registry=true)
            
            for (i, pkg) in pairs(all_pkgs)
                entry = Pkg.Types.manifest_info(ctx.env.manifest, pkg.uuid)
                is_dep = pkg.name in orig_pkg_names
                # Handle different Julia versions
                if VERSION >= v"1.11"
                    all_pkgs[i] = update_package_add(ctx, pkg, entry, false, false, is_dep)
                else
                    all_pkgs[i] = update_package_add(ctx, pkg, entry, is_dep)
                end
            end
            
            foreach(pkg -> ctx.env.project.deps[pkg.name] = pkg.uuid, all_pkgs)
            
            # Pass 2 resolution
            pkgs2, deps_map2 = _resolve(ctx.io, ctx.env, ctx.registries, all_pkgs, PRESERVE_NONE, ctx.julia_version)
            
            # Collect any new weak dependencies from pass 2
            resolved_uuids2 = Set([pkg.uuid for pkg in pkgs2])
            new_weak_deps = Set{String}()
            
            for (pkg_uuid, deps) in pairs(deps_map2)
                for (dep_name, dep_uuid) in pairs(deps)
                    if !(dep_uuid in resolved_uuids2) && !(dep_name in blacklisted) && !(dep_name in all_package_names)
                        push!(new_weak_deps, dep_name)
                    end
                end
            end
            
            if !isempty(new_weak_deps)
                println("Found additional weak dependencies from pass 2: $new_weak_deps")
                
                # Final pass: Add the new weak dependencies too
                union!(all_package_names, new_weak_deps)
                all_package_names = setdiff(all_package_names, blacklisted)
                
                # Create fresh specs for all packages including new weak deps
                final_pkgs = [PackageSpec(name) for name in all_package_names]
                
                # Reset and resolve everything together
                empty!(ctx.env.project.deps)
                
                # Apply overrides
                for pkg in final_pkgs
                    if pkg.name in keys(overrides)
                        pkg.path = overrides[pkg.name]
                    end
                end
                
                project_deps_resolve!(ctx.env, final_pkgs)
                registry_resolve!(ctx.registries, final_pkgs)
                stdlib_resolve!(final_pkgs)
                ensure_resolved(ctx, ctx.env.manifest, final_pkgs, registry=true)
                
                for (i, pkg) in pairs(final_pkgs)
                    entry = Pkg.Types.manifest_info(ctx.env.manifest, pkg.uuid)
                    is_dep = pkg.name in orig_pkg_names
                    # Handle different Julia versions
                    if VERSION >= v"1.11"
                        final_pkgs[i] = update_package_add(ctx, pkg, entry, false, false, is_dep)
                    else
                        final_pkgs[i] = update_package_add(ctx, pkg, entry, is_dep)
                    end
                end
                
                foreach(pkg -> ctx.env.project.deps[pkg.name] = pkg.uuid, final_pkgs)
                
                # Final resolution
                global pkgs, deps_map = _resolve(ctx.io, ctx.env, ctx.registries, final_pkgs, PRESERVE_NONE, ctx.julia_version)
            else
                # No new weak deps in pass 2, use pass 2 results
                global pkgs, deps_map = pkgs2, deps_map2
            end
        end
    else
        # Julia < 1.9, no weak dependency support
        pkgs, deps_map = _resolve(ctx.io, ctx.env, ctx.registries, pkgs, PRESERVE_NONE, ctx.julia_version)
    end
  '';

  juliaExpression = packageNames: ''
    import Pkg
    Pkg.Registry.add(Pkg.RegistrySpec(path="${augmentedRegistry}"))

    import Pkg.Types: Context, PackageSpec

    input = ${lib.generators.toJSON {} packageNames}

    if isfile("extra_package_names.txt")
      append!(input, readlines("extra_package_names.txt"))
    end

    input = unique(input)

    println("Resolving packages: " * join(input, " "))

    pkgs = [PackageSpec(pkg) for pkg in input]

    ctx = Context()

    ${resolveCode}

    open(ENV["out"], "w") do io
      for spec in pkgs
        println(io, "- name: " * spec.name)
        println(io, "  uuid: " * string(spec.uuid))
        println(io, "  version: " * string(spec.version))
        if endswith(spec.name, "_jll") && haskey(deps_map, spec.uuid)
          println(io, "  depends_on: ")
          for (dep_name, dep_uuid) in pairs(deps_map[spec.uuid])
            println(io, "    \"$(dep_name)\": \"$(dep_uuid)\"")
          end
        end
      end
    end
  '';
in

runCommand "julia-package-closure.yml" { buildInputs = [julia (python3.withPackages (ps: with ps; [pyyaml]))]; } ''
  mkdir home
  export HOME=$(pwd)/home

  echo "Resolving Julia packages with the following inputs"
  echo "Julia: ${julia}"
  echo "Registry: ${augmentedRegistry}"

  # Prevent a warning where Julia tries to download package server info
  export JULIA_PKG_SERVER=""

  julia -e '${juliaExpression packageNames}';

  # See if we need to add any extra package names based on the closure
  # and the packageImplications
  python ${./python}/find_package_implications.py "$out" '${lib.generators.toJSON {} packageImplications}' extra_package_names.txt

  if [ -f extra_package_names.txt ]; then
    echo "Re-resolving with additional package names"
    julia -e '${juliaExpression packageNames}';
  fi
''
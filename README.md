## P3Deps

[P3Deps](https://github.com/clempo2/P3Deps) is a Perl script that analyzes the dependencies in a P3 Unity project and outputs a report of missing and unused assets.

The [P3 SDK](https://www.multimorphic.com/support/projects/customer-support/wiki/3rd-Party_Development_Kit) is a development kit distributed by [Multimorphic](https://www.multimorphic.com/) to help the development of games on the [P3 Pinball platform](https://www.multimorphic.com/p3-pinball-platform/).

A P3 Unity project is an application written in [Unity](https://unity.com/) using the P3 SDK.

P3Deps was developped against P3_SDK_V0.8 primarily to trim down P3SampleApp. P3Deps is likely to be useful with any P3 project since almost all P3 projects can be traced back to P3SampleApp originally.

## Installation

P3Deps assumes the development platform is Windows.

Prerequisite: P3Deps requires Perl 5 be installed on the PC.

Perl comes bundled with [Git for Windows](https://git-scm.com/download/win). If you have Git for Windows installed, Perl is already available. Just make sure to add C:\Program Files\Git\usr\bin to your Windows PATH.

If you don't have Git for Windows and don't want to install it, consider installing [ActivePerl](https://www.activestate.com/products/perl/) instead.

To install P3Deps:
- Just copy p3deps.pl anywhere on your PC.

## Instructions

P3Deps does not modify the P3 Unity project in any way. The only thing it does is print out a report on standard output.

In order for P3Deps to read the assets, the Unity serialization must be changed to YAML. This can be done on a copy of the project. It does not have to be a permanent change.

- Start Unity and open the P3 project.
- In the top menu, select Edit/Project Settings/Editor.
- In the Inspector, Change Asset Serialiazation Mode to Force Text.
- Wait for the assets to be rewritten.

- In a command prompt, type the following command:  perl path_to_p3deps absolute_path_to_project  
  where path_to_p3deps is the path to the p3deps.pl file  
  and absolute_path_to_project is the absolute path to the project directory.
  
  For example: perl c:/p3deps.pl c:/P3_SDK_V0.8/P3SampleApp > report.txt

  Perl can get confused with relative paths. Make sure you use an absolute path to the project.  
  We recommend forward slashes instead of backslashes to make the output work better.  
- Revert the Serialization Mode if desired.

P3Deps will emit a report with the following information:
- A tree of the dependencies among used assets starting from every root
- Missing resources that are referenced but could not be found in the project
- A sample script to delete all the unused assets

The next step is best performed on a copy of your project or after all changes have been committed to git.

If you choose to trim your project:
- Extract the rm and rmdir commands from the output and write them in a new batch file like rmdeps.bat
- Verify carefully that all these files and directories are indeed not needed.
- Add C:\Program Files\Git\usr\bin to your PATH if not already there.
- Execute: rmdeps.bat

## Theory of Operations

P3Deps starts with a list of assets it knows are used in the project:
- the enabled scenes in the project build settings
- Assets/Plugins
- Assets/Editor
- Assets/Gizmos
- Assets/Resources/Prefabs/Framework
- Assets/Scripts/GUI/${AppCode}Setup.cs
- A few resources loaded by the SDK

P3Deps traverses the assets starting from these roots and follows references to other assets. For scripts, P3Deps finds referenced classes, calls to Resources.Load(), calls to PlaySound() and PlaySound3D().

## Support

Please submit a [GitHub issue](https://github.com/clempo2/P3Deps/issues) if you find a problem.

You can discuss P3Deps and other P3 Development topics on the [P3 Community Discord Server](https://discord.gg/GuKGcaDkjd) in the dev-forum channel under the 3rd Party Development section.

## License

Copyright (c) 2023 Clement Pellerin  
MIT License.

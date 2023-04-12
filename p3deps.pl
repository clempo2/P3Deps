# P3Deps - Analyze dependencies in a P3 Unity project
# Copyright (c) 2023 Clement Pellerin  
# MIT License.

use strict;
use warnings;
use File::Find;

if (@ARGV < 1) {
  print "Usage: perl p3deps.pl <project>\n";
  print "where project is the absolute path to the P3 Unity project\n";
  exit;
}

my $project = $ARGV[0];
my $assets = "$project/Assets";
my $appconfig = "$project/Configuration/AppConfig.json";
my $buildsettings = "$project/ProjectSettings/EditorBuildSettings.asset";

if (!(-d "$assets" and -f "$appconfig" and -f $buildsettings)) {
  print "The path '$project' is not a P3 Unity project\n";
  exit;
}

# set of scene names in the project build settings
my %scenes = ();

# set of root assets that are known to be used
my %roots = ();

# maps resource path (without extension) to asset path (with extension)
my %fullpaths = ();

# set of directory paths under Assets
my %dirs = ();

# maps asset path to guid
my %guids = ();

# maps guid to asset path
my %paths = ();

# maps a class name to its file path
my %classes = ();

# maps script asset path to set of identifiers in the source
my %identifiers = ();

# maps asset path to set of guid references
my %refs = ();

# maps asset path to set of resources used
my %resources = ();

# maps asset path to set of dependency paths
my %deps = ();

# set of asset paths used by the project
my %used = ();

# set of resources used but missing
my %missing = ();

# find the scene names from the project build settings and mark them as roots
find_scenes();

# find all dirs, meta files and the asset guids
find(\&process_file, $assets);

# add some hardcoded roots
mark_roots("$assets/Resources/Prefabs/Framework");
mark_roots("$assets/Editor");
mark_roots("$assets/Gizmos");
mark_roots("$assets/Plugins");
delete_roots("/libpinproc.*");
delete_roots("/mysql.data.dll");

my $appcode = find_appcode();
my $appsetup = "$assets/Scripts/GUI/${appcode}Setup.cs";
$roots{$appsetup} = 1;

# add some resources loaded by the SDK, fake they are loaded by ${appcode}Setup.cs
$resources{$appsetup}{"$assets/Resources/Fonts/tunga"} = 1;
$resources{$appsetup}{"$assets/Resources/Fonts/sf distant galaxy alternate italic"} = 1;
$resources{$appsetup}{"$assets/Resources/Prefabs/${appcode}Setup"} = 1;
$resources{$appsetup}{"$assets/Resources/Prefabs/${appcode}NamedLocations"} = 1;
$resources{$appsetup}{"$assets/Resources/Prefabs/${appcode}PopupScore"} = 1;
$resources{$appsetup}{"$assets/Resources/Prefabs/GUI/LEDSimulator"} = 1;
$resources{$appsetup}{"$assets/Resources/Prefabs/GUI/PopupMessage"} = 1;
$resources{$appsetup}{"$assets/Resources/Prefabs/GUI/TwitchChatBot"} = 1;

# find all the assets used by the project by traversing from the roots
foreach my $root (sort keys %roots) {
  traverse($root, "");
}

print "\n\n\n\n =========== Used Assets ===========\n";
foreach my $path (sort keys %used) {
  print "$path\n";
}

print "\n\n\n\n =========== Missing Resources ===========\n";
foreach my $path (sort keys %missing) {
  print "$path\n";
}

print "\n\n\n\n =========== Unused Assets  ===========\n";
my $standard_assets = "$assets/Standard Assets";
foreach my $path (sort keys %guids) {
  if (!$used{$path} and rindex($path, $standard_assets, 0) == -1) {
    print "rm \"$path.meta\"\n" if (-f "$path.meta");
    print "rm \"$path\"\n";
  }
}

foreach my $dir (reverse sort keys %dirs) {
  if (!is_used_dir($dir) and rindex($dir, $standard_assets, 0) == -1) {
    print "rm \"$dir.meta\"\n";
    print "rmdir \"$dir\"\n";
  }
}

if (-f "$project/ReleaseNotes") {
  print "\n\nThe ./ReleaseNotes can be removed if unmodified from the SDK.\n";
}

if (-d "$project/Documentation") {
  print "\n\nThe ./Documentation directory can also be removed from your project\n";
}

exit;

# given a used asset, traverse its dependencies to mark them used
sub traverse {
  my $path = $_[0];
  my $indent = $_[1];
  if ($used{$path}) {
    print "$indent$path [again]\n";
  }
  else {
    $used{$path} = 1;
    print "$indent$path\n";

    my %refguids = %{$refs{$path}};
    foreach my $refguid (sort keys %refguids) {
      if (defined $paths{$refguid}) {
        traverse($paths{$refguid}, $indent . "  ");
      } 
      #else {
      #  print "$indent  Unknown $refguid\n";
      #}
    }

    my %resourceset = %{$resources{$path}};
    foreach my $resource (sort keys %resourceset) {
      my $respath = resource_fullpath($resource);
      if ($respath) {
        traverse($respath, $indent . "  ");
      }
      else {
        $missing{$resource} = 1;
      }
    }

    if (defined $identifiers{$path}) {
      my %identifierset = %{$identifiers{$path}};
      foreach my $identifier (sort keys %identifierset) {
        my $impl = $classes{$identifier};
        if ($impl and $impl ne $path) {
          traverse($impl, $indent . "  ");
        }
      }
    }
  }
}

sub resource_fullpath {
  my $resource = $_[0];
  foreach my $path (keys %guids) {
    return $path if $path =~ m/^\Q$resource\E\.\w+$/;
  }

  # print "Unknown resource $resource\n";
  return ""; # false
}

sub show_all_refs {
  print "Refs ======================\n";
  foreach my $path (keys %guids) {
    print "$path\n";
    
    my %guidset = %{$refs{$path}};
    foreach my $guid (keys %guidset) {
      if (defined $paths{$guid}) {
        print "  $paths{$guid}\n";
      } 
      else {
        print "  Unknown $guid\n";
      }
    }
  }
}

sub show_all_resources {
  print "Resources ======================\n";
  foreach my $path (keys %guids) {
    print "$path\n";
    
    my %resourceset = %{$resources{$path}};
    foreach my $resource (keys %resourceset) {
      print "  $resource\n";
    }
  }
}

sub process_file {
  if (-f $_ && $_ =~ /^\.DS_Store$/) {
    $guids{$File::Find::name} = "null";
  }
  elsif (-f $_ && $_ =~ /\.meta$/) {
    my $meta = $File::Find::name;
    
    my $path = $meta;
    $path =~ s/\.meta$//;

    my $respath = $path;
    $respath =~ s/\.[^.]+$//;
    $fullpaths{$respath} = $path;
    $refs{$path} = {};
    $deps{$path} = {};
    $resources{$path} = {};

    if (-d $path) {
      $dirs{$path} = 1;
    }
    elsif (-f $path) {
      my $guid = read_guid($meta);
      $guids{$path} = $guid;
      $paths{$guid} = $path;

      if ($path =~ /\.cs$/) {
        process_script($path);
      }
      elsif (!is_binary($path)) {
        process_asset($path);
      }
    }
  }
}

sub read_guid {
  my $meta = $_[0];
  my $contents = read_file($meta);
  $contents =~ m/\bguid: (.*)/;
  my $guid = $1;
  $guid || die "Missing guid in meta file $meta";
}

sub process_script {
  my $path = $_[0];
  # find all class implementations in this script
  my $code = read_script($path);
  foreach my $class ($code =~ m/\bclass\s+(\w+)/g) {
    $classes{$class} = $path;
  }

  # find all resources loaded explicitly by this script
  foreach my $loadarg ($code =~ m/Resources.Load\s*(?:<\s*\w+\s*>\s*)?\(([^)]*)/g) {
    # check for the only expression we recognize
    # Resources.Load("Prefabs/" + sceneName + "/BallSave")
    if ($loadarg =~ m#^\"Prefabs/\" \+ sceneName \+ \"/([^\"]+)\"$#) {
      my $prefab = $1;
      foreach my $scene (keys %scenes) {
        my $resource = "$assets/Resources/Prefabs/$scene/$prefab";
        if (-f "$resource.prefab") {
          $resources{$path}{$resource} = 1;
        }
      }
    }
    elsif ($loadarg =~ m/^\s*\"([^\"]+)\"\s*$/) {
      my $resource = "$assets/Resources/$1";
      $resources{$path}{$resource} = 1;
    }
    #else {
    #  print "Unrecognized resource in Resources.Load=$loadarg\n";
    #}
  }

  # find audio clips played by this script
  # P3SAAudio.Instance.PlaySound("FX/Blackout");
  # P3SAAudio.Instance.PlaySound3D("PlayerAdded", gameObject.transform);
  foreach my $play ($code =~ m/PlaySound3?D?\s*\(([^)]*)/g) {
    if ($play =~ m/^\s*\"([^"]+)\"/) {
      my $sound = "$assets/Resources/Sound/$1";
      $resources{$path}{$sound} = 1;
    }
  }

  # find all identifiers in the code, some of them might be class names
  foreach my $identifier ($code =~ m/\w+/g) {
    $identifiers{$path}{$identifier} = 1;
  }
}

sub process_asset {
  my $path = $_[0];
  my $asset = read_file($path);
  
  foreach my $ref ($asset =~ m/, guid: ([^,]*),/g) {
    $refs{$path}{$ref} = 1;
  }

  foreach my $clip ($asset =~ m/^\s*(?:clipName|\w+Clip): (.*)$/mg) {
    if ($clip =~ m/\w/) {
      $clip =~ tr/\\/\//;
      my $resource = "$assets/Resources/Sound/$clip";
      $resources{$path}{$resource} = 1;
    }
  }
}
  
# find the enabled scenes in the build settings
# don't use a YAML package, we want to run on bare Git Perl distribution

sub find_scenes {
  open(my $fh, '<', $buildsettings) or die "Can't open file $buildsettings: $!";
  my $enabled = "0";
  
  while (my $line = <$fh>) {
    chomp $line;
    if ($line =~ /- enabled: (\d)/) {
      $enabled = $1;
    }
    elsif ($line =~ m/path: (.*)/) {
      if ($enabled) {
        my $path = $1;
        my $root = "$project/$path";
        $roots{$root} = 1;
        $path =~ m/.*\/(\w+)\.unity$/;
        my $scene = $1;
        $scenes{$scene} = 1;
      }
    }
  }

  close $fh;
}

# mark every file under the specified directory (and subdirs) as roots
sub mark_roots {
  my $dir = $_[0];
  my $dirpath = $dir . "/";
  foreach my $path (keys %guids) {
    $roots{$path} = 1 if rindex($path, $dirpath, 0) == 0;
  }
}

# delete roots that match a pattern
sub delete_roots {
  my $pattern = $_[0];
  foreach my $path (keys %guids) {
    delete $roots{$path} if $path =~ m/$pattern/;
  }
}

sub find_appcode {
  my $contents = read_file($appconfig);
  $contents =~ m/\"Name\": \"(\w+)\"/;
  $appcode = $1;
  $appcode || die "Cannot find app code in $appconfig\n";
  return $appcode;
}

sub is_binary {
  my $filename = $_[0];
  return ($filename =~ /\.(ogg|wav|sfk|mp3|png|zip|ttf|tif|so|dylib|dll|tga|jpg|psd)$/);
}

# List of extensions in P3SampleApp
# .physicmaterial
# .ogg
# .cubemap
# .manifest
# .js
# .zip
# .def
# .ttf
# .fbx
# .fontsettings
# .meta
# .mixer
# .html
# .shader
# .controller
# .tif
# .so
# .prefab
# .mat
# .FBX
# .wav
# .dylib
# .DS_Store
# .cginc
# .anim
# .cs
# .flare
# .tga
# .jpg
# .png
# .unity
# .physicMaterial
# .mp3
# .dll
# .psd
# .asset
# .txt
# .sfk

sub is_used_dir {
  my $dir = $_[0];
  my $dirpath = $dir . "/";

  foreach my $path (keys %used) {
    return 1 if rindex($path, $dirpath, 0) == 0;
  }

  return 0;
}

sub read_file {
  my $path = $_[0];
  my $content = "";
  
  open(my $fh, "<", $path) or die "Could not open file '$path' $!";
  {
    local $/;
    $content = <$fh>;
  }

  close($fh);
  return $content;
}

sub read_script {
  my $path = $_[0];
  my $code = read_file($path);
  $code = remove_comments($code);
  return $code;
}

sub remove_comments {
  my $code = $_[0];
  # taken from https://metacpan.org/pod/perlfaq6#How-do-I-use-a-regular-expression-to-strip-C-style-comments-from-a-file
  $code =~ s#/\*[^*]*\*+([^/*][^*]*\*+)*/|//([^\\]|[^\n][\n]?)*?\n|("(\\.|[^"\\])*"|'(\\.|[^'\\])*'|.[^/"'\\]*)#defined $3 ? $3 : ""#gse;
  return $code;
}

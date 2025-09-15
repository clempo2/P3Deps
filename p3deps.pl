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

my $contents = read_file($buildsettings);
if (!($contents =~ /^%YAML/)) {
  print "Error: asset serialization must be in YAML\n";
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

# maps a class name to its file path, struct and enum are considered classes
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

my $baseGameMode = read_script("$assets/Scripts/Modes/${appcode}BaseGameMode.cs");
my $twitchEnabled = $baseGameMode =~ m/enableTwitchIntegration\s*=\s*true/;

# add some resources loaded by the SDK, fake they are loaded by ${appcode}Setup.cs
$resources{$appsetup}{"$assets/Resources/Fonts/tunga"} = 1;
$resources{$appsetup}{"$assets/Resources/Fonts/sf distant galaxy alternate italic"} = 1;
$resources{$appsetup}{"$assets/Resources/Prefabs/${appcode}Setup"} = 1;
$resources{$appsetup}{"$assets/Resources/Prefabs/${appcode}NamedLocations"} = 1;
$resources{$appsetup}{"$assets/Resources/Prefabs/${appcode}PopupScore"} = 1;
$resources{$appsetup}{"$assets/Resources/Prefabs/GUI/LEDSimulator"} = 1;
$resources{$appsetup}{"$assets/Resources/Prefabs/GUI/PopupMessage"} = 1;
if ($twitchEnabled) {
  $resources{$appsetup}{"$assets/Resources/Prefabs/GUI/TwitchChatBot"} = 1;
}

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
    print "rm \"$path\"\n" if (-f $path);
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

# this collects information about every file
# without regards if it is used by the project or not

sub process_file {
  if (-d $_) {
    $dirs{$File::Find::name} = 1;
  }
  elsif (-f $_ and $_ =~ /\.meta$/) {
    my $meta = $File::Find::name;

    my $path = $meta;
    $path =~ s/\.meta$//;

    init_path($path);

    if (-d $path) {
      $dirs{$path} = 1;
    }
    else {
      my $guid = read_guid($meta);
      $guids{$path} = $guid;
      $paths{$guid} = $path;
    }
  }
  elsif (-f $_ and $_ !~ /\.meta$/) {
    my $path = $File::Find::name;
    
    if (! -f "$_.meta") {
      # files without a .meta file
      $guids{$path} = "null";
    }

    init_path($path);

    if ($path =~ /\.cs$/) {
      process_script($path);
    }
    elsif (!is_binary($path)) {
      process_asset($path);
    }
  }
}

# read a .meta file and extract the asset guid

sub read_guid {
  my ($meta) = @_;
  my $contents = read_file($meta);
  $contents =~ m/\bguid: (\w*)/;
  my $guid = $1;
  $guid || die "Missing guid in meta file $meta";
}

# initialize the state for a new path
# do it only once because it will be called for the path and its .meta file
# in case one or the other is missing

sub init_path {
  my ($path) = @_;

  if (! $resources{$path}) {
    $resources{$path} = {};
    $refs{$path} = {};
    $deps{$path} = {};

    my $respath = $path;
    $respath =~ s/\.[^.]+$//;
    $fullpaths{$respath} = $path;
  }
}

sub process_script {
  my ($path) = @_;
  my $code = read_script($path);

  # find prefabs in string literals
  # selectorManagerMode.RegisterSelector(new SettingsSelectorMode(p3, Priorities.PRIORITY_SERVICE_MODE), "SettingsEditor", "Prefabs/Framework/SettingsEditor");
  foreach my $prefab ($code =~ m/\"(Prefabs\/[^\"]*[^\"\/])\"/g) {
    my $resource = "$assets/Resources/$prefab";
    $resources{$path}{$resource} = 1;
  }

  # find all resources loaded explicitly by this script
  # Resources.Load("Prefabs/Framework/ButtonLegend");
  # Resources.Load<GameObject>("Prefabs/P3SAAudio");
  # Resources.Load("Prefabs/" + sceneName + "/BallSave")
  foreach my $loadarg ($code =~ m/Resources\.Load\s*(?:<\s*\w+\s*>\s*)?\(([^)]*)/g) {
    if ($loadarg =~ m/^\s*\"([^\"]+)\"\s*$/) {
      my $resource = "$assets/Resources/$1";
      $resources{$path}{$resource} = 1;
    }
    # check for this exact expression
    # Resources.Load("Prefabs/" + sceneName + "/BallSave")
    elsif ($loadarg =~ m#^\"Prefabs/\" \+ sceneName \+ \"/([^\"]+)\"$#) {
      my $prefab = $1;
      foreach my $scene (keys %scenes) {
        my $resource = "$assets/Resources/Prefabs/$scene/$prefab";
        if (-f "$resource.prefab") {
          $resources{$path}{$resource} = 1;
        }
      }
    }
    # check for an expression with constant prefix
    # containing parent directory and stem of filename
    # Resources.Load("Prefabs/X_Scoring_" + value.ToString() + "X")
    elsif ($loadarg =~ m#^\"([^"]+)/([^"/]+)\"\s*\+#) {
      my $dir = $1;
      my $stem = $2;
      my @files = find_files_with_stem("$assets/Resources/$dir", $stem);
      foreach my $file (@files) {
	if ($file =~ /^(.*)\.prefab$/) {
	   my $not_resource = "$assets/Resources/$dir/$stem";
	   delete $resources{$path}{$not_resource};
	   my $prefab = $1;
	   my $resource = "$assets/Resources/$dir/$prefab";
           $resources{$path}{$resource} = 1;
	}
      }
    }
    #else {
    #  print "Unrecognized resource in Resources.Load=$loadarg\n";
    #}
  }

  # find audio clips played by this script
  # BEWARE of a Perl bug if you try to use the | operator in those regexp's

  # P3SAAudio.Instance.PlaySound("FX/Blackout");
  # P3SAAudio.Instance.PlaySound3D("PlayerAdded", gameObject.transform);
  foreach my $play ($code =~ m/PlaySound3?D?\s*\(([^,)]*)/g) {
    process_sound($path, $play);
  }

  # PlayEdgeSound("SideTargetUnlit", (bool)eventObject);
  foreach my $play ($code =~ m/PlayEdgeSound\s*\(([^,)]*)/g) {
    process_sound($path, $play);
  }

  # PostModeEventToGUI("Evt_PlaySound", "FX/HitSound");
  foreach my $play ($code =~ m/PostModeEventToGUI\s*\(\s*\"Evt_PlaySound\",\s*([^)]*)/g) {
    process_sound($path, $play);
  }

  # remove string literals because we don't want to confuse them as identifiers
  $code =~ s/"(?:[^"\\]|\\.)*"//g;

  # find all class implementations in this script
  foreach my $class ($code =~ m/\b(?:class|struct|enum)\s+(\w+)/g) {
    $classes{$class} = $path;
  }

  # find all identifiers in the code, some might be a class, struct or enum ref
  foreach my $identifier ($code =~ m/\w+/g) {
    $identifiers{$path}{$identifier} = 1;
  }
}

sub process_sound {
  my ($path, $play) = @_;
  # check for a constant
  if ($play =~ m/^\s*\"([^"]+)\"$/) {
    my $sound = "$assets/Resources/Sound/$1";
    $resources{$path}{$sound} = 1;
  }
  # check for an expression with constant prefix
  # containing parent directory and stem of filename
  elsif ($play =~ m/^\"([^"]+)/) {
    my $stem = $1;
    my @files = find_files_with_stem("$assets/Resources/Sound", $stem);
    foreach my $file (@files) {
      if ($file =~ /^(.*)\.(wav|mp3|ogg)$/) {
         my $sound = "$assets/Resources/Sound/$1";
         $resources{$path}{$sound} = 1;
      }
    }
  }
}

sub process_asset {
  my ($path) = @_;
  my $asset = read_file($path);
  
  foreach my $ref ($asset =~ m/, guid: ([^,]*),/g) {
    $refs{$path}{$ref} = 1;
  }

  while ($asset =~ m/^\s*(clipName|\w+Clip): ([^\r\n]*)/mg) {
    my $property = $1;
    my $clip = $2;
    if ($property ne "m_NearClip" and $property ne "m_FarClip" and $clip =~ m/\w/) {
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
    elsif ($line =~ m/path: ([^\r\n]*)/) {
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
  my ($dir) = @_;
  my $dirpath = $dir . "/";
  foreach my $path (keys %guids) {
    $roots{$path} = 1 if rindex($path, $dirpath, 0) == 0;
  }
}

# delete roots that match a pattern
sub delete_roots {
  my ($pattern) = @_;
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

# given a used asset, traverse its dependencies to mark them used
sub traverse {
  my ($path, $indent) = @_;

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
  my ($resource) = @_;

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

sub is_binary {
  my ($filename) = @_;
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
  my ($dir) = @_;
  my $dirpath = $dir . "/";

  foreach my $path (keys %used) {
    return 1 if rindex($path, $dirpath, 0) == 0;
  }

  return 0;
}

sub read_file {
  my ($path) = @_;
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
  my ($path) = @_;
  my $code = read_file($path);
  $code = remove_comments($code);
  return $code;
}

sub remove_comments {
  my ($code) = @_;
  # taken from https://metacpan.org/pod/perlfaq6#How-do-I-use-a-regular-expression-to-strip-C-style-comments-from-a-file
  $code =~ s#/\*[^*]*\*+([^/*][^*]*\*+)*/|//([^\\]|[^\n][\n]?)*?\n|("(\\.|[^"\\])*"|'(\\.|[^'\\])*'|.[^/"'\\]*)#defined $3 ? $3 : ""#gse;
  return $code;
}

sub find_files_with_stem {
    my ($dir, $stem) = @_;
    opendir(my $dh, $dir) or die "Cannot open directory '$dir': $!";
    my @matches = grep { /^$stem/ && -f "$dir/$_" } readdir($dh);
    closedir($dh);
    return @matches;
}

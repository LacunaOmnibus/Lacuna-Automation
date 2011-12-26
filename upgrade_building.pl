#!/usr/bin/perl

use strict;

use Client;
use Getopt::Long;
use JSON::XS;

my $config_name = "config.json";
my $body_name;
my $building_name;
my $level;

GetOptions(
  "config=s"   => \$config_name,
  "body=s"     => \$body_name,
  "building=s" => \$building_name,
  "level=i"    => \$level,
) or die "$0 --config=foo.json --body=Bar --building=Mine --level=1\n";

my $client = Client->new(config => $config_name);
my $body_id;
if ($body_name) {
  my $planets = $client->empire_status->{planets};
  for my $id (keys(%$planets)) {
    $body_id = $id if $planets->{$id} =~ /$body_name/;
  }
  die "No matching planet for name $body_name\n" unless $body_id;
} else {
  $body_id = $client->empire_status->{home_planet_id};
}

my $result = $client->body_buildings($body_id);

for my $id (keys %{$result->{buildings}}) {
  my $building = $result->{buildings}{$id};
  if ($building->{name} =~ /$building_name/ &&
      (!$level || $building->{level} == $level)) {
    my $upgrade = $client->building_upgrade($building->{url}, $id);
    print "Upgrade complete at ".Client::format_time(Client::parse_time($upgrade->{building}{pending_build}{end}))."\n";
    exit(0);
  }
}

die "No matching building for name $building_name level $level\n";

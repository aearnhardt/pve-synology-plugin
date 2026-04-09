package PVE::Storage::Custom::SynologyStoragePlugin;

# Upstream: https://github.com/aearnhardt/pve-synology-plugin

use strict;
use warnings;

use Digest::MD5 qw(md5_hex);
use File::Basename qw( basename dirname );
use File::Path ();
use Cwd qw( abs_path );

use PVE::JSONSchema ();
use PVE::Tools qw( file_get_contents file_read_firstline run_command );
use PVE::Storage         ();
use PVE::Storage::Plugin ();

use JSON::XS qw( decode_json encode_json );
use LWP::UserAgent ();
use HTTP::Request  ();
use URI::Escape qw( uri_escape uri_escape_utf8 );
use Time::HiRes qw( sleep );

use base qw(PVE::Storage::Plugin);

push @PVE::Storage::Plugin::SHARED_STORAGE, 'synology';

my $DEBUG = $ENV{ SYNOLOGY_DEBUG } // 0;

sub get_debug_level {
  my ($scfg) = @_;
  return $scfg->{ debug } if ref($scfg) eq 'HASH' && defined $scfg->{ debug };
  return $DEBUG;
}

sub set_debug_from_config {
  my ($scfg) = @_;
  if ( ref($scfg) eq 'HASH' && defined $scfg->{ debug } ) {
    $DEBUG = $scfg->{ debug };
  }
}

### PVE API version (match Nimble plugin pattern)
sub api {
  my $tested_apiver = 13;
  my $apiver        = eval { PVE::Storage::APIVER() };
  my $apiage        = eval { PVE::Storage::APIAGE() };
  $apiver = $tested_apiver if !defined($apiver) || $apiver !~ /^\d+$/;
  $apiage = 0              if !defined($apiage) || $apiage !~ /^\d+$/;
  if ( $apiver >= 2 && $apiver <= $tested_apiver ) {
    return $apiver;
  }
  if ( $apiver - $apiage < $tested_apiver ) {
    return $tested_apiver;
  }
  return 10;
}

sub type {
  return 'synology';
}

sub plugindata {
  return {
    content => [ { images => 1, none => 1 }, { images => 1 } ],
    format  => [ { raw => 1 }, 'raw' ],
    # Do NOT set 'sensitive-properties' => {} — in PVE::Storage::Plugin::sensitive_properties() an empty
    # hash is truthy, so the API returns no sensitive keys and omits password from the default list.
    # Omitting the key uses Proxmox's backward-compat default, which includes "password" (like CIFS).
  };
}

sub properties {
  return {
    address => {
      description => 'Synology DSM hostname or IP (no https:// prefix). Also used as default iSCSI portal if iscsi_discovery_ips is unset.',
      type        => 'string',
    },
    dsm_port => {
      description => 'DSM HTTPS port (default 5001) or HTTP port if use_https=no (default 5000).',
      type        => 'integer',
      default     => 5001,
    },
    use_https => {
      description => 'Use HTTPS for DSM Web API.',
      type        => 'boolean',
      default     => 'yes',
    },
    check_ssl => {
      description => 'Verify DSM TLS certificate (default no for typical self-signed NAS certs).',
      type        => 'boolean',
      default     => 'no',
    },
    target_name => {
      description => 'Existing iSCSI target name on the Synology (SAN Manager). LUNs are mapped to this target. Allow this host\'s initiator IQN or use "Allow all" on the target.',
      type        => 'string',
    },
    lun_location => {
      description => 'Storage location for new LUNs (e.g. /volume1). Must exist on the NAS; same as in DSM when creating a LUN manually.',
      type        => 'string',
    },
    lun_type => {
      description => 'LUN type passed to DSM (e.g. ADV, THIN, BLUN, FILE). Default ADV (Ext4 thin / advanced); use BLUN on Btrfs pools.',
      type        => 'string',
      default     => 'ADV',
    },
    vnprefix => {
      description => 'Optional prefix for LUN names on the Synology.',
      type        => 'string',
    },
    iscsi_port => {
      description => 'iSCSI target port for discovery/login (default 3260).',
      type        => 'integer',
      default     => 3260,
    },
    iscsi_discovery_ips => {
      description => 'Comma-separated iSCSI portals (host or host:port). Defaults to address:iscsi_port.',
      type        => 'string',
    },
    auto_iscsi_discovery => {
      description => 'On storage activate, run iSCSI sendtargets and node login (default yes).',
      type        => 'boolean',
      default     => 'yes',
    },
    dsm_session => {
      description => 'Optional SYNO.API.Auth session name (e.g. Core). Leave unset unless DSM requires it for your account.',
      type        => 'string',
      optional    => 1,
    },
    max_iscsi_sessions => {
      description => 'When ensuring the iSCSI target, set max concurrent sessions to at least this value (default 32).',
      type        => 'integer',
      default     => 32,
    },
    debug => {
      description => 'Debug verbosity 0–3.',
      type        => 'integer',
      minimum     => 0,
      maximum     => 3,
      default     => 0,
    },
    storeid => {
      description => 'Proxmox storage ID (auto-set; do not change manually).',
      type        => 'string',
      optional    => 1,
    },
  };
}

sub options {
  return {
    address                => { fixed => 1 },
    username               => { fixed => 1 },
    password               => { optional => 1 },
    target_name            => { fixed => 1 },
    lun_location           => { fixed => 1 },
    dsm_port               => { optional => 1 },
    use_https              => { optional => 1 },
    check_ssl              => { optional => 1 },
    lun_type               => { optional => 1 },
    vnprefix               => { optional => 1 },
    iscsi_port             => { optional => 1 },
    iscsi_discovery_ips    => { optional => 1 },
    auto_iscsi_discovery   => { optional => 1 },
    dsm_session            => { optional => 1 },
    max_iscsi_sessions     => { optional => 1 },
    debug                  => { optional => 1 },
    storeid                => { optional => 1 },
    nodes                  => { optional => 1 },
    disable                => { optional => 1 },
    content                => { optional => 1 },
    format                 => { optional => 1 },
  };
}

sub check_config {
  my ( $class, $sectionId, $config, $create, $skipSchemaCheck ) = @_;
  my $opts = $class->SUPER::check_config( $sectionId, $config, $create, $skipSchemaCheck );
  if ( ref($opts) eq 'HASH' && defined $sectionId && $sectionId ne '' ) {
    $opts->{ storeid } = $sectionId;
    # Never persist password in storage.cfg: mirror to priv (same paths as hooks) and drop from opts.
    if ( defined( $opts->{ password } ) && $opts->{ password } ne '' ) {
      synology_set_password( $sectionId, $opts->{ password } );
      delete $opts->{ password };
    }
  }
  return $opts;
}

### Priv paths (password mirror — same pattern as Nimble)
sub synology_password_file_paths {
  my ($storeid) = @_;
  return () if !defined $storeid || $storeid eq '';
  return (
    "/etc/pve/priv/storage/${storeid}.pw",
    "/etc/pve/priv/storage/${storeid}.synology.pw",
    "/etc/pve/priv/synology/${storeid}.pw",
  );
}

sub synology_password_ensure_parent_dirs {
  for my $dir ( '/etc/pve/priv/storage', '/etc/pve/priv/synology' ) {
    next if -d $dir;
    eval { File::Path::make_path( $dir, { mode => 0700 } ); };
    die "Error :: cannot create $dir: $@\n" if $@ || !-d $dir;
  }
}

sub synology_set_password {
  my ( $storeid, $password ) = @_;
  synology_password_ensure_parent_dirs();
  for my $f ( synology_password_file_paths($storeid) ) {
    PVE::Tools::file_set_contents( $f, "$password\n", 0600, 1 );
  }
}

sub synology_read_password_file {
  my ($storeid) = @_;
  return undef if !defined $storeid || $storeid eq '';
  for my $f ( synology_password_file_paths($storeid) ) {
    next unless -f $f;
    my $c = PVE::Tools::file_get_contents($f);
    next unless defined $c;
    chomp $c;
    return $c if length $c;
  }
  return undef;
}

sub synology_delete_password_file {
  my ($storeid) = @_;
  for my $f ( synology_password_file_paths($storeid) ) {
    unlink $f if -e $f;
  }
}

sub on_add_hook {
  my ( $class, $storeid, $scfg, %sensitive ) = @_;
  if ( exists $sensitive{ password } ) {
    my $pw = $sensitive{ password };
    if ( defined($pw) && $pw ne '' ) {
      synology_set_password( $storeid, $pw );
    }
    else {
      synology_delete_password_file($storeid);
    }
  }
  elsif ( ref($scfg) eq 'HASH' && defined( $scfg->{ password } ) && $scfg->{ password } ne '' ) {
    # Legacy: plaintext password still present in cfg (pre sensitive-properties); mirror to priv files.
    synology_set_password( $storeid, $scfg->{ password } );
  }
  return;
}

sub on_update_hook {
  my ( $class, $storeid, $opts, %sensitive ) = @_;
  $opts //= {};
  if ( exists $sensitive{ password } ) {
    my $pw = $sensitive{ password };
    if ( defined($pw) && $pw ne '' ) {
      synology_set_password( $storeid, $pw );
    }
    else {
      synology_delete_password_file($storeid);
    }
  }
  elsif ( exists $opts->{ password } && defined( $opts->{ password } ) && $opts->{ password } ne '' ) {
    synology_set_password( $storeid, $opts->{ password } );
  }
  return;
}

sub on_delete_hook {
  my ( $class, $storeid, $scfg ) = @_;
  synology_delete_password_file($storeid);
  my $sidf = synology_sid_cache_path($storeid);
  unlink $sidf if -e $sidf;
  return;
}

sub on_update_hook_full {
  my ( $class, $storeid, $scfg, $opts, $delete, $sensitive ) = @_;
  $opts      //= {};
  $delete    //= [];
  $sensitive //= {};
  my %del = map { $_ => 1 } @$delete;
  if ( exists $opts->{ password } ) {
    my $pw = $opts->{ password };
    if ( defined($pw) && $pw ne '' ) {
      synology_set_password( $storeid, $pw );
    }
    else {
      synology_delete_password_file($storeid);
    }
  }
  elsif ( $del{ password } ) {
    synology_delete_password_file($storeid);
  }
  return;
}

sub synology_effective_storeid {
  my ( $scfg, $storeid ) = @_;
  return $storeid if defined $storeid && $storeid ne '';
  return $scfg->{ storeid } if ref($scfg) eq 'HASH' && defined $scfg->{ storeid } && $scfg->{ storeid } ne '';
  return '';
}

sub synology_dsm_credentials {
  my ( $scfg, $storeid ) = @_;
  my $sid = synology_effective_storeid( $scfg, $storeid );
  die "Error :: Synology: missing storage id for API credentials.\n" if $sid eq '';
  my $user = $scfg->{ username } // '';
  my $pass = $scfg->{ password };
  $pass = synology_read_password_file($sid) if !defined($pass) || $pass eq '';
  die "Error :: Synology: password not configured for storage \"$sid\".\n" if !defined($pass) || $pass eq '';
  die "Error :: Synology: username not configured.\n" if $user eq '';
  return ( $user, $pass );
}

sub synology_dsm_host {
  my ($scfg) = @_;
  my $a = $scfg->{ address } // '';
  $a =~ s{\Ahttps?://}{}i;
  $a =~ s{/.*}{};
  $a =~ s{:\d+\z}{};
  die "Error :: Synology: invalid or empty address.\n" if $a eq '';
  return $a;
}

sub synology_sid_cache_path {
  my ($storeid) = @_;
  return "/etc/pve/priv/synology/${storeid}.sid.json";
}

# DSM query values for string params often use JSON-style double quotes (Synology CSI driver).
sub dsm_string_param {
  my ($s) = @_;
  $s //= '';
  $s =~ s/\\/\\\\/g;
  $s =~ s/"/\\"/g;
  return '"' . $s . '"';
}

# entry.cgi returns generic WEBAPI_* codes 100–119 (same numbering as older DSM docs).
sub synology_dsm_generic_webapi_hint {
  my ($code) = @_;
  return '' if !defined $code || "$code" !~ /^\d+$/;
  my $c = 0 + $code;
  my %h = (
    100 => 'unknown',
    101 => 'bad request',
    102 => 'no such API',
    103 => 'no such method (not implemented for this API version, or unsupported on this DSM/SAN Manager build)',
    104 => 'unsupported API version (version= above SYNO.API.Info max for the API, or request does not match method schema for that version)',
    105 => 'no permission',
    106 => 'session timeout',
    107 => 'session interrupted',
  );
  my $t = $h{$c};
  # ASCII separator only: UTF-8 em dash shows as mojibake in some PVE task dialogs.
  return $t ? " - $t" : '';
}

sub synology_dsm_base {
  my ($scfg) = @_;
  my $host = synology_dsm_host($scfg);
  my $https = !defined( $scfg->{ use_https } ) || "$scfg->{use_https}" !~ /^(0|no|false)$/i;
  my $port;
  if ( defined $scfg->{ dsm_port } && "$scfg->{dsm_port}" =~ /^\d+$/ ) {
    $port = 0 + $scfg->{ dsm_port };
  }
  else {
    $port = $https ? 5001 : 5000;
  }
  my $scheme = $https ? 'https' : 'http';
  return ( $scheme, $host, $port );
}

sub synology_lwp_agent {
  my ($scfg) = @_;
  my $ua = LWP::UserAgent->new(
    timeout => 120,
    ssl_opts => {
      verify_hostname => ( $scfg->{ check_ssl } && "$scfg->{check_ssl}" =~ /^(1|yes|true)$/i ) ? 1 : 0,
      SSL_verify_mode => ( $scfg->{ check_ssl } && "$scfg->{check_ssl}" =~ /^(1|yes|true)$/i ) ? 0x01 : 0x00,
    },
  );
  $ua->env_proxy;
  return $ua;
}

sub synology_read_sid_cache {
  my ($storeid) = @_;
  my $path = synology_sid_cache_path($storeid);
  return undef unless -f $path;
  my $raw = eval { file_get_contents($path) };
  return undef unless defined $raw && $raw ne '';
  my $j = eval { decode_json($raw) };
  return undef unless ref($j) eq 'HASH' && defined $j->{ sid } && length $j->{ sid };
  return $j->{ sid };
}

sub synology_write_sid_cache {
  my ( $storeid, $sid ) = @_;
  synology_password_ensure_parent_dirs();
  my $dir = '/etc/pve/priv/synology';
  eval { File::Path::make_path( $dir, { mode => 0700 } ); };
  my $path = synology_sid_cache_path($storeid);
  my $tmp  = "$path.tmp.$$";
  my $payload = encode_json( { sid => $sid, saved => time() } );
  PVE::Tools::file_set_contents( $tmp, $payload, 0600, 1 );
  rename( $tmp, $path ) or die "Error :: cannot write SID cache: $!\n";
}

sub synology_clear_sid_cache {
  my ($storeid) = @_;
  my $path = synology_sid_cache_path($storeid);
  unlink $path if -e $path;
}

sub synology_dsm_login {
  my ( $scfg, $storeid ) = @_;
  my ( $user, $pass ) = synology_dsm_credentials( $scfg, $storeid );
  my ( $scheme, $host, $port ) = synology_dsm_base($scfg);
  my $url = "$scheme://${host}:${port}/webapi/auth.cgi";
  my @q = (
    api     => 'SYNO.API.Auth',
    version => '3',
    method  => 'login',
    account => $user,
    passwd  => $pass,
    format  => 'sid',
  );
  if ( defined $scfg->{ dsm_session } && length $scfg->{ dsm_session } ) {
    push @q, session => $scfg->{ dsm_session };
  }
  my @pairs;
  for ( my $i = 0; $i < @q; $i += 2 ) {
    push @pairs, uri_escape_utf8( $q[$i] ) . '=' . uri_escape_utf8( $q[ $i + 1 ] );
  }
  my $uri = $url . '?' . join( '&', @pairs );
  my $ua  = synology_lwp_agent($scfg);
  my $req = HTTP::Request->new( GET => $uri );
  my $res = $ua->request($req);
  die "Error :: Synology DSM login HTTP " . $res->code . "\n" unless $res->is_success;
  my $body = $res->decoded_content // '';
  my $data = eval { decode_json($body) };
  die "Error :: Synology DSM login: invalid JSON\n" if $@ || ref($data) ne 'HASH';
  if ( !$data->{ success } ) {
    my $code = $data->{ error }->{ code } // '?';
    die "Error :: Synology DSM login failed (code $code).\n";
  }
  my $sid = $data->{ data }->{ sid } // '';
  die "Error :: Synology DSM login: no sid in response.\n" if $sid eq '';
  synology_write_sid_cache( synology_effective_storeid( $scfg, $storeid ), $sid );
  return $sid;
}

sub synology_ensure_sid {
  my ( $scfg, $storeid ) = @_;
  my $sid = synology_effective_storeid( $scfg, $storeid );
  my $cached = synology_read_sid_cache($sid);
  return $cached if length $cached;
  return synology_dsm_login( $scfg, $storeid );
}

# SYNO.API.Info query for one API name (same idea as synology_lun_gui SynologyClient.api_info_max_version).
# Returns undef if the query fails; otherwise maxVersion capped at 15. Callers that need a version
# probe range combine this with a fallback (see volume_snapshot_rollback).
sub synology_api_info_max_version {
  my ( $scfg, $storeid, $api_name ) = @_;
  $api_name //= '';
  return undef if $api_name eq '';
  my $sid = synology_ensure_sid( $scfg, $storeid );
  my ( $scheme, $host, $port ) = synology_dsm_base($scfg);
  my $qurl = "$scheme://${host}:${port}/webapi/query.cgi";
  my $uri = $qurl . '?'
    . join( '&',
    uri_escape_utf8('api') . '=' . uri_escape_utf8('SYNO.API.Info'),
    uri_escape_utf8('version') . '=' . uri_escape_utf8('1'),
    uri_escape_utf8('method') . '=' . uri_escape_utf8('query'),
    uri_escape_utf8('query') . '=' . uri_escape_utf8($api_name) );
  my $ua  = synology_lwp_agent($scfg);
  my $req = HTTP::Request->new( GET => $uri );
  $req->header( 'Cookie' => "id=$sid" );
  my $res = $ua->request($req);
  return undef unless $res->is_success;
  my $body = $res->decoded_content // '';
  my $data = eval { decode_json($body) };
  return undef if $@ || ref($data) ne 'HASH' || !$data->{ success };
  my $root = $data->{ data };
  return undef if ref($root) ne 'HASH';
  my $slot = $root->{ $api_name };
  return undef if ref($slot) ne 'HASH';
  my $max = $slot->{ maxVersion };
  $max = $slot->{ max_version } if !defined $max;
  return undef if !defined $max || "$max" !~ /^\d+$/;
  my $m = 0 + $max;
  return undef if $m < 1;
  return 15 if $m > 15;
  return $m;
}

# $params: list of key/value for query string (values already escaped where needed)
sub synology_entry_request {
  my ( $scfg, $storeid, $params_ref, $retry ) = @_;
  $retry //= 1;
  my $sid = synology_ensure_sid( $scfg, $storeid );
  my ( $scheme, $host, $port ) = synology_dsm_base($scfg);
  my $url = "$scheme://${host}:${port}/webapi/entry.cgi";
  my @pairs;
  my $pr = $params_ref;
  for ( my $i = 0; $i < @$pr; $i += 2 ) {
    my $k = $pr->[ $i ];
    my $v = $pr->[ $i + 1 ];
    push @pairs, uri_escape_utf8($k) . '=' . uri_escape_utf8($v);
  }
  my $uri = $url . '?' . join( '&', @pairs );
  my $ua  = synology_lwp_agent($scfg);
  my $req = HTTP::Request->new( GET => $uri );
  $req->header( 'Cookie' => "id=$sid" );
  my $res = $ua->request($req);
  die "Error :: Synology API HTTP " . $res->code . "\n" unless $res->is_success;
  my $body = $res->decoded_content // '';
  my $data = eval { decode_json($body) };
  die "Error :: Synology API: invalid JSON ($body)\n" if $@ || ref($data) ne 'HASH';

  if ( !$data->{ success } ) {
    my $code = $data->{ error }->{ code };
    if ($retry) {
      if ( defined $code && ( $code == 105 || $code == 106 || $code == 119 ) ) {
        synology_clear_sid_cache( synology_effective_storeid( $scfg, $storeid ) );
        return synology_entry_request( $scfg, $storeid, $params_ref, 0 );
      }
    }
    my ( $which_api, $which_method ) = ( '', '' );
    for ( my $i = 0; $i < @$pr; $i += 2 ) {
      my $pk = $pr->[$i] // '';
      my $pv = $pr->[ $i + 1 ] // '';
      $which_api    = $pv if $pk eq 'api';
      $which_method = $pv if $pk eq 'method';
    }
    my $where = ( $which_api ne '' || $which_method ne '' )
      ? " ($which_api / $which_method)"
      : '';
    die "Error :: Synology API$where error code "
      . ( defined $code ? $code : '?' )
      . synology_dsm_generic_webapi_hint($code) . ".\n";
  }
  return $data->{ data };
}

# Byte-for-byte same as SynologyOpenSource/synology-csi LunList (spaces after commas). Some DSM 7.2
# builds return 18990517 / HTTP 500 if this JSON is compact (no spaces).
sub synology_lun_types_list_param {
  return '["BLOCK", "FILE", "THIN", "ADV", "SINK", "CINDER", "CINDER_BLUN", "CINDER_BLUN_THICK", "BLUN", "BLUN_THICK", "BLUN_SINK", "BLUN_THICK_SINK"]';
}

# Same spelling as CSI LUN list/get "additional" (note space before "is_action_locked").
sub synology_lun_additional_list_param {
  # Add spaces after every comma inside the string. vpd_unit_sn matches Linux VPD serial (often with dashes).
  return dsm_string_param(
    '["allocated_size", "status", "flashcache_status", "is_action_locked", "vpd_unit_sn"]');
}

# Thin LUN types: pass can_snapshot=1 at create (Synology CSI / democratic-csi). Thick FILE,
# BLOCK, BLUN_THICK, etc. omit this — DSM does not support snapshots for those modes.
sub synology_lun_create_dev_attribs {
  my ($lun_type) = @_;
  my %snap_ok = map { $_ => 1 } qw(
    THIN ADV BLUN BLUN_SINK CINDER CINDER_BLUN
  );
  return '[]' if !$lun_type || !$snap_ok{$lun_type};
  return encode_json( [ { dev_attrib => 'can_snapshot', enable => 1 } ] );
}

sub synology_api_target_list {
  my ( $class, $scfg, $storeid ) = @_;
  my $data = eval {
    synology_entry_request(
      $scfg, $storeid,
      [
        api          => 'SYNO.Core.ISCSI.Target',
        method       => 'list',
        version      => '1',
        additional   => dsm_string_param('["mapped_lun", "connected_sessions"]'),
      ],
    )
  };
  if ($@) {
    my $err = $@;
    if ($err =~ /error code 18990517/) {
      $data = synology_entry_request(
        $scfg, $storeid,
        [
          api          => 'SYNO.Core.ISCSI.Target',
          method       => 'list',
          version      => '1',
        ]
      );
    } else {
      die $err;
    }
  }
  my $list = $data->{ targets };
  return ref($list) eq 'ARRAY' ? $list : [];
}

sub synology_api_lun_list {
  my ( $class, $scfg, $storeid ) = @_;
  my $data;

  my @attempts = (
    [
      api        => 'SYNO.Core.ISCSI.LUN',
      method     => 'list',
      version    => '1',
      types      => synology_lun_types_list_param(),
      additional => synology_lun_additional_list_param(),
    ],
    [
      api        => 'SYNO.Core.ISCSI.LUN',
      method     => 'list',
      version    => '1',
      types      => synology_lun_types_list_param(),
    ],
    [
      api        => 'SYNO.Core.ISCSI.LUN',
      method     => 'list',
      version    => '1',
    ],
  );

  my $last_err;
  for my $q (@attempts) {
    $data = eval { synology_entry_request( $scfg, $storeid, $q ) };
    if ($@) {
      $last_err = $@;
      # If DSM rejects the payload shape (e.g. DSM 7.2+), fallback to simpler params
      if ($last_err =~ /error code 18990517/) {
        next;
      }
      die $last_err;
    }
    $last_err = undef;
    last;
  }
  die $last_err if defined $last_err;

  my $list = $data->{ luns };
  return ref($list) eq 'ARRAY' ? $list : [];
}

sub synology_resolve_target {
  my ( $class, $scfg, $storeid ) = @_;
  my $want = $scfg->{ target_name } // '';
  die "Error :: Synology: target_name not set.\n" if $want eq '';
  my $targets = $class->synology_api_target_list( $scfg, $storeid );
  for my $t (@$targets) {
    next unless ref($t) eq 'HASH';
    return $t if ( $t->{ name } // '' ) eq $want;
  }
  die "Error :: Synology: iSCSI target \"$want\" not found on NAS. Create it in DSM SAN Manager.\n";
}

sub synology_ensure_target_sessions {
  my ( $class, $scfg, $storeid ) = @_;
  my $t    = $class->synology_resolve_target( $scfg, $storeid );
  my $tid  = $t->{ target_id };
  my $want = $scfg->{ max_iscsi_sessions } // 32;
  $want = 32 if !defined $want || "$want" !~ /^\d+$/;
  $want = 0 + $want;
  my $cur = $t->{ max_sessions } // 0;
  $cur = 0 + $cur;
  return if $cur >= $want;
  synology_entry_request(
    $scfg, $storeid,
    [
      api         => 'SYNO.Core.ISCSI.Target',
      method      => 'set',
      version     => '1',
      target_id   => dsm_string_param("$tid"),
      max_sessions => "$want",
    ],
  );
}

sub synology_name_prefix {
  my ($scfg) = @_;
  return $scfg->{ vnprefix } // '';
}

sub synology_array_lun_name {
  my ( $scfg, $volname ) = @_;
  return synology_name_prefix($scfg) . $volname;
}

sub synology_find_lun_by_volname {
  my ( $class, $scfg, $volname, $storeid ) = @_;
  my $full = synology_array_lun_name( $scfg, $volname );
  for my $lun ( @{ $class->synology_api_lun_list( $scfg, $storeid ) } ) {
    next unless ref($lun) eq 'HASH';
    return $lun if ( $lun->{ name } // '' ) eq $full;
  }
  return undef;
}

sub synology_lun_get {
  my ( $class, $scfg, $storeid, $uuid ) = @_;
  my $data = eval {
    synology_entry_request(
      $scfg, $storeid,
      [
        api        => 'SYNO.Core.ISCSI.LUN',
        method     => 'get',
        version    => '1',
        uuid       => dsm_string_param($uuid),
        additional => synology_lun_additional_list_param(),
      ],
    )
  };
  if ($@) {
    my $err = $@;
    if ($err =~ /error code 18990517/) {
      $data = synology_entry_request(
        $scfg, $storeid,
        [
          api        => 'SYNO.Core.ISCSI.LUN',
          method     => 'get',
          version    => '1',
          uuid       => dsm_string_param($uuid),
        ]
      );
    } else {
      die $err;
    }
  }
  my $lun = $data->{ lun };
  return ref($lun) eq 'HASH' ? $lun : undef;
}

sub synology_lun_serial_hints {
  my ($lun) = @_;
  return [] unless ref($lun) eq 'HASH';
  my %seen;
  my @out;
  for my $k (qw( uuid vpd_unit_sn )) {
    my $raw = $lun->{ $k } // '';
    next if $raw eq '';
    my $n = synology_serial_normalize($raw);
    next if length($n) < 8;
    push @out, $n if !$seen{$n}++;
  }
  return \@out;
}

sub synology_lun_serial_guess {
  my ($lun) = @_;
  my $h = synology_lun_serial_hints($lun);
  return $h->[0] // '';
}

sub synology_untaint_iscsi_scalar {
  my ($v) = @_;
  return '' unless defined $v && length $v;
  $v =~ s/^\s+|\s+$//g;
  return '' if $v eq '';
  return $1 if $v =~ /^([A-Za-z0-9.\[\]:,_=+-]+)$/ && length($1) <= 512;
  return '';
}

sub synology_untaint_dev_path {
  my ($p) = @_;
  return '' unless defined $p && length $p;
  return $1 if $p =~ m{^(/dev/dm-\d+)$};
  return $1 if $p =~ m{^(/dev/sd[a-z]+)$};
  return $1 if $p =~ m{^(/dev/nvme\d+n\d+(?:p\d+)?)$};
  return $1 if $p =~ m{^(/dev/disk/by-id/[a-zA-Z0-9_.:@+=-]+)$};
  return '';
}

sub synology_untaint_multipath_wwid {
  my ($w) = @_;
  return '' unless defined $w && length $w;
  return $1 if $w =~ /^([a-zA-Z0-9_.:@+=-]+)$/;
  return '';
}

sub synology_serial_normalize {
  my ($s) = @_;
  return '' unless defined $s;
  $s =~ s/^\s+|\s+$//g;
  $s =~ s/\s+//g;
  $s =~ s/-//g;
  return lc $s;
}

sub synology_serial_exact {
  my ( $a, $b ) = @_;
  return 0 if !length($a) || !length($b);
  return synology_serial_normalize($a) eq synology_serial_normalize($b);
}

sub synology_serial_matches {
  my ( $a, $b ) = @_;
  return 0 if !length($a) || !length($b);
  my $x = synology_serial_normalize($a);
  my $y = synology_serial_normalize($b);
  return 1 if $x eq $y;
  return 1 if index( $y, $x ) >= 0 || index( $x, $y ) >= 0;
  return 0;
}

# Return a stable /dev/disk/by-id/... path when possible so QEMU keeps the correct LUN across scans;
# fall back to the resolved block device (/dev/sdX, /dev/dm-N).
sub synology_resolve_by_id_entry {
  my ( $full, $basename ) = @_;
  return ( '', '' ) unless -l $full;
  my $target = readlink($full);
  return ( '', '' ) unless defined $target;
  my $abs = abs_path( dirname($full) . '/' . $target );
  return ( '', '' ) unless $abs && -b $abs;
  my $wwid = '';
  if ( $basename =~ /^dm-uuid-mpath-(.+)/ ) {
    $wwid = synology_untaint_multipath_wwid($1);
  }
  elsif ( $basename =~ /^wwn-0x([0-9a-f]+)$/i ) {
    $wwid = synology_untaint_multipath_wwid( $1 );
  }
  my $by_id_safe = synology_untaint_dev_path($full);
  return ( $by_id_safe, $wwid ) if length($by_id_safe) && -b $by_id_safe;
  my $safe = synology_untaint_dev_path($abs);
  return ( $safe, $wwid );
}

sub synology_by_id_pick_best {
  my (@pool) = @_;
  return ( '', '' ) if !@pool;
  my %best_for_abs;
  for my $r (@pool) {
    my $k = $r->{ abs };
    my $cur = $best_for_abs{$k};
    if ( !$cur ) {
      $best_for_abs{$k} = $r;
      next;
    }
    my $score = sub {
      my ($x) = @_;
      return 3 if $x->{ e } =~ /^dm-uuid-mpath-/i;
      return 2 if $x->{ e } =~ /^wwn-0x/i;
      return 1;
    };
    $best_for_abs{$k} = $r if $score->($r) > $score->($cur);
  }
  my @uniq = values %best_for_abs;
  @uniq = sort {
    my $sb = ( $b->{ e } =~ /^dm-uuid-mpath-/i ) <=> ( $a->{ e } =~ /^dm-uuid-mpath-/i );
    return $sb if $sb;
    my $sw = ( $b->{ e } =~ /^wwn-0x/i ) <=> ( $a->{ e } =~ /^wwn-0x/i );
    return $sw if $sw;
    length( $a->{ e } ) <=> length( $b->{ e } );
  } @uniq;
  if ( @uniq > 1 ) {
    warn "Warning :: Synology: ambiguous device match for serial hint; using $uniq[0]->{path} ("
      . scalar(@uniq)
      . " distinct disks matched). Check /dev/disk/by-id vs DSM LUN uuid.\n";
  }
  my $w = $uniq[0];
  return ( $w->{ path }, $w->{ wwid } // '' );
}

# When udev has not created /dev/disk/by-id links (some iSCSI setups), match by sysfs serial on
# whole-disk block nodes (sdX, vdX, nvme*n*, dm-* if they expose device/serial).
sub synology_match_block_devices_by_serial {
  my ($serial) = @_;
  my $sys = '/sys/block';
  opendir( my $dh, $sys ) or return ( '', '' );
  my ( @exact_pool, @fuzzy_pool );
  while ( my $e = readdir($dh) ) {
    next if $e =~ /^\.\.?$/;
    next unless $e =~ /^(sd[a-z]+|vd[a-z]+|nvme\d+n\d+|dm-\d+)$/;
    my $ser_path = "/sys/block/$e/device/serial";
    next unless -f $ser_path;
    my $line = file_read_firstline($ser_path);
    next unless defined $line && $line =~ /^\s*(.+?)\s*$/;
    my $ds = $1;
    my $devpath = "/dev/$e";
    next unless -b $devpath;
    my $safe = synology_untaint_dev_path($devpath);
    next unless length($safe);
    my $rec = { e => $e, path => $safe, wwid => '', abs => $safe };
    if ( synology_serial_exact( $serial, $ds ) ) {
      push @exact_pool, $rec;
    }
    elsif ( synology_serial_matches( $serial, $ds ) ) {
      push @fuzzy_pool, $rec;
    }
  }
  closedir($dh);
  my ( $p, $w ) = synology_by_id_pick_best(@exact_pool);
  return ( $p, $w ) if length($p);
  return synology_by_id_pick_best(@fuzzy_pool);
}

sub synology_normalize_iqn_cmp {
  my ($v) = @_;
  return '' unless defined $v && length $v;
  $v =~ s/^\s+|\s+$//g;
  return lc $v;
}

sub synology_find_iscsi_targetname_for_scsi_device {
  my ($scsi_dev_abs) = @_;
  return undef unless defined $scsi_dev_abs && length $scsi_dev_abs;
  my $cur = $scsi_dev_abs;
  for ( 1 .. 30 ) {
    last if !length($cur) || $cur eq '/';
    if ( -f "$cur/targetname" ) {
      my $line = file_read_firstline("$cur/targetname");
      if ( defined $line && $line =~ /^\s*(.+?)\s*$/ ) {
        my $t = $1;
        return $t if length($t) && index( lc($t), 'iqn.' ) == 0;
      }
    }
    for my $g ( glob("$cur/session*/targetname"), glob("$cur/iscsi_session/session*/targetname") ) {
      next unless defined $g && -f $g;
      my $line = file_read_firstline($g);
      if ( defined $line && $line =~ /^\s*(.+?)\s*$/ ) {
        my $t = $1;
        return $t if length($t) && index( lc($t), 'iqn.' ) == 0;
      }
    }
    $cur = dirname($cur);
  }
  return undef;
}

# When serial/VPD matching fails, map DSM lun_id to Linux H:B:T:L and confirm iSCSI target IQN.
sub synology_try_scsi_lun_device {
  my ( $want_lun, $want_iqn ) = @_;
  $want_iqn = synology_normalize_iqn_cmp($want_iqn);
  return ( '', '' ) if !length($want_iqn);
  $want_lun = 0 + $want_lun;
  my $sys = '/sys/block';
  opendir( my $dh, $sys ) or return ( '', '' );
  my @hits;
  while ( my $e = readdir($dh) ) {
    next if $e =~ /^\.\.?$/;
    next unless $e =~ /^(sd[a-z]+)$/;
    my $lnk = "$sys/$e/device";
    next unless -l $lnk;
    my $abs = abs_path($lnk);
    next unless length($abs) && $abs =~ m{/(\d+):(\d+):(\d+):(\d+)\z};
    my $lun = 0 + $4;
    next unless $lun == $want_lun;
    my $tn = synology_find_iscsi_targetname_for_scsi_device($abs);
    next unless defined $tn && length($tn);
    next unless synology_normalize_iqn_cmp($tn) eq $want_iqn;
    my $devpath = "/dev/$e";
    next unless -b $devpath;
    my $safe = synology_untaint_dev_path($devpath);
    push @hits, $safe if length($safe);
  }
  closedir($dh);
  if ( @hits > 1 ) {
    warn "Warning :: Synology: multiple sd devices for LUN $want_lun on \"$want_iqn\"; using $hits[0]\n";
  }
  return ( $hits[0] // '', '' );
}

sub synology_block_path_for_lun {
  my ( $class, $storeid, $scfg, $lun ) = @_;
  return ( '', '' ) unless ref($lun) eq 'HASH';
  my $hints = synology_lun_serial_hints($lun);
  for my $h (@$hints) {
    my ( $p, $w ) = synology_get_device_path_by_serial($h);
    return ( $p, $w ) if length($p) && -b $p;
  }
  my $lid = $lun->{ lun_id };
  if ( defined $lid && "$lid" =~ /^-?[0-9]+$/ ) {
    my $iqn_raw = eval { $class->synology_target_iqn( $scfg, $storeid ); } // '';
    my $iqn = synology_untaint_iscsi_scalar($iqn_raw);
    return synology_try_scsi_lun_device( 0 + $lid, $iqn ) if length($iqn);
  }
  return ( '', '' );
}

sub synology_get_device_path_by_serial {
  my ($serial) = @_;
  die 'Error :: Synology: volume serial hint missing' unless length($serial);
  my $sn = synology_serial_normalize($serial);
  return ( '', '' ) unless length($sn);

  my $by_id = '/dev/disk/by-id';
  if ( -d $by_id && $sn =~ /^[0-9a-f]{8,}$/ ) {
    for my $name ( "wwn-0x$sn", "wwn-$sn", "scsi-3$sn" ) {
      my $full = "$by_id/$name";
      next unless -e $full;
      my ( $dev, $ww ) = synology_resolve_by_id_entry( $full, $name );
      return ( $dev, $ww ) if length($dev) && -b $dev;
    }
  }

  if ( -d $by_id && length($sn) >= 8 ) {
    opendir( my $dh, $by_id ) or goto SYSFS_SCAN;
    my @hit = grep {
      $_ !~ /^\.\.?$/ && $_ !~ /-part\d+\z/ && index( lc($_), $sn ) >= 0;
    } readdir($dh);
    closedir($dh);
    @hit = sort {
      my $ma = ( lc($a) =~ /^dm-uuid-mpath-/ );
      my $mb = ( lc($b) =~ /^dm-uuid-mpath-/ );
      ( $mb <=> $ma )
        || ( ( lc($b) =~ /^wwn-0x/ ) <=> ( lc($a) =~ /^wwn-0x/ ) )
        || ( length($a) <=> length($b) );
    } @hit;
    for my $e (@hit) {
      my $full = "$by_id/$e";
      my ( $dev, $ww ) = synology_resolve_by_id_entry( $full, $e );
      return ( $dev, $ww ) if length($dev) && -b $dev;
    }
  }

SYSFS_SCAN:
  my ( @exact_pool, @fuzzy_pool );
  if ( -d $by_id && opendir( my $dh2, $by_id ) ) {
    while ( my $e = readdir($dh2) ) {
      next if $e =~ /^\.\.?$/;
      my $full = "$by_id/$e";
      next unless -l $full;
      my $target = readlink($full);
      next unless defined $target;
      my $abs = abs_path( dirname($full) . '/' . $target );
      next unless $abs && -b $abs;
      my $blk      = basename($abs);
      my $ser_path = "/sys/block/$blk/device/serial";
      next unless -f $ser_path;
      my $line = file_read_firstline($ser_path);
      next unless defined $line && $line =~ /^\s*(.+?)\s*$/;
      my $ds = $1;
      my $stable = synology_untaint_dev_path($full);
      $stable = synology_untaint_dev_path($abs) if !length($stable);
      next unless length($stable) && -b $stable;
      my $wwid = '';
      if ( $e =~ /^dm-uuid-mpath-(.+)/ ) {
        $wwid = synology_untaint_multipath_wwid($1);
      }
      elsif ( $e =~ /^wwn-0x([0-9a-f]+)$/i ) {
        $wwid = synology_untaint_multipath_wwid($1);
      }
      my $rec = { e => $e, path => $stable, wwid => $wwid, abs => $abs };
      if ( synology_serial_exact( $serial, $ds ) ) {
        push @exact_pool, $rec;
      }
      elsif ( synology_serial_matches( $serial, $ds ) ) {
        push @fuzzy_pool, $rec;
      }
    }
    closedir($dh2);
  }
  my ( $p, $w ) = synology_by_id_pick_best(@exact_pool);
  return ( $p, $w ) if length($p);
  ( $p, $w ) = synology_by_id_pick_best(@fuzzy_pool);
  return ( $p, $w ) if length($p);
  return synology_match_block_devices_by_serial($serial);
}

sub synology_iscsiadm_path {
  return -x '/usr/bin/iscsiadm' ? '/usr/bin/iscsiadm' : '/sbin/iscsiadm';
}

sub synology_iscsi_portal {
  my ( $host, $port ) = @_;
  $port //= 3260;
  return "$host:$port";
}

sub synology_discovery_portals {
  my ($scfg) = @_;
  my $port = $scfg->{ iscsi_port } // 3260;
  $port = 3260 if "$port" !~ /^\d+$/;
  $port = 0 + $port;
  my @out;
  if ( defined $scfg->{ iscsi_discovery_ips } && length $scfg->{ iscsi_discovery_ips } ) {
    for my $chunk ( split /\s*,\s*/, $scfg->{ iscsi_discovery_ips } ) {
      next if $chunk eq '';
      if ( $chunk =~ /:\d+\z/ ) {
        push @out, $chunk;
      }
      else {
        push @out, synology_iscsi_portal( $chunk, $port );
      }
    }
    return @out if @out;
  }
  my $h = synology_dsm_host($scfg);
  return ( synology_iscsi_portal( $h, $port ) );
}

sub synology_sendtargets {
  my ($scfg) = @_;
  my $adm = synology_iscsiadm_path();
  return unless -x $adm;
  for my $portal ( synology_discovery_portals($scfg) ) {
    my $p = synology_untaint_iscsi_scalar($portal);
    next unless length $p;
    eval {
      run_command( [ $adm, '-m', 'discovery', '-t', 'sendtargets', '-p', $p ], timeout => 25, quiet => 1 );
    };
  }
}

sub synology_auto_iscsi_discovery_enabled {
  my ($scfg) = @_;
  return 0 unless ref($scfg) eq 'HASH';
  my $v = $scfg->{ auto_iscsi_discovery };
  return 1 if !defined($v);
  return 0 if "$v" eq '0' || "$v" eq 'no';
  return 1;
}

sub synology_target_iqn {
  my ( $class, $scfg, $storeid ) = @_;
  my $t = $class->synology_resolve_target( $scfg, $storeid );
  return $t->{ iqn } // '';
}

sub synology_iscsi_login_all {
  my ($scfg) = @_;
  my $adm = synology_iscsiadm_path();
  return unless -x $adm;
  eval { run_command( [ $adm, '-m', 'node', '--op', 'update', '-n', 'node.startup', '-v', 'automatic' ], timeout => 10, quiet => 1 ); };
  eval { run_command( [ $adm, '-m', 'node', '--login' ], timeout => 120, quiet => 1 ); };
}

sub synology_snapshot_dsm_name {
  my ( $volname, $snap ) = @_;
  return 'pve-' . md5_hex( $volname . "\0" . $snap );
}

### --- PVE storage plugin API ---

sub parse_volname {
  my ( $class, $volname ) = @_;
  if ( $volname =~ m/^(vm|base)-(\d+)-(\S+)$/ ) {
    my $vtype = ( $1 eq 'vm' ) ? 'images' : 'base';
    return ( $vtype, $3, $2, undef, undef, undef, 'raw' );
  }
  die "Error :: Invalid volume name ($volname).\n";
}

sub filesystem_path {
  my ( $class, $scfg, $volname, $snapname, $storeid ) = @_;
  die "Error :: filesystem_path: snapshot path not supported ($snapname)\n" if defined $snapname;
  my ( $vtype, undef, $vmid ) = $class->parse_volname($volname);
  my $lun = $class->synology_find_lun_by_volname( $scfg, $volname, $storeid );
  die "Error :: Volume \"$volname\" not found on Synology.\n" unless $lun;
  my $hints = synology_lun_serial_hints($lun);
  my $lid = $lun->{ lun_id };
  die "Error :: No uuid/vpd_unit_sn/lun_id for \"$volname\" (cannot map to /dev).\n"
    if !@$hints && !( defined $lid && "$lid" =~ /^-?[0-9]+$/ );
  my ( $path, $wwid ) = synology_block_path_for_lun( $class, $storeid, $scfg, $lun );
  if ( !length($path) ) {
    # destroy_vm() only calls vdisk_free when PVE::Storage::path() returns a truthy
    # path. With no local iSCSI session the LUN is not under /dev, so path was "" and
    # disks stayed on the NAS unless "Destroy unreferenced disks" ran (that path uses
    # vdisk_list + vdisk_free and skips the path check). In list context report a stub
    # path so ownership checks pass; vdisk_free still uses DSM API. Scalar callers
    # (e.g. qemu_blockdev_options) keep "" so -b fails until map_volume has run.
    if (wantarray) {
      my $u = $lun->{ uuid } // '';
      $u =~ s/[^0-9a-fA-F]//g;
      my $stub = length($u) ? "/run/pve/synology-unmapped/$u" : "/run/pve/synology-unmapped/novaliduuid";
      return ( $stub, $vmid, $vtype, '' );
    }
    return "";
  }
  $path = synology_untaint_dev_path($path) || $path;
  return wantarray ? ( $path, $vmid, $vtype, $wwid ) : $path;
}

sub path {
  my ( $class, $scfg, $volname, $storeid, $snapname ) = @_;
  return $class->filesystem_path( $scfg, $volname, $snapname, $storeid );
}

sub find_free_diskname {
  my ( $class, $storeid, $scfg, $vmid, $fmt, $add_fmt_suffix ) = @_;
  my $list = $class->synology_list_volume_entries( $scfg, $storeid );
  my @disk_list = map { $_->{ name } } @$list;
  return PVE::Storage::Plugin::get_next_vm_diskname( \@disk_list, $storeid, $vmid, undef, $scfg );
}

sub synology_list_volume_entries {
  my ( $class, $scfg, $storeid ) = @_;
  my $prefix = synology_name_prefix($scfg);
  my @rows;
  for my $lun ( @{ $class->synology_api_lun_list( $scfg, $storeid ) } ) {
    next unless ref($lun) eq 'HASH';
    my $n = $lun->{ name } // '';
    next if length($prefix) && index( $n, $prefix ) != 0;
    my $volname = length($prefix) ? substr( $n, length($prefix) ) : $n;
    next unless $volname =~ /^vm-(\d+)-(disk-|cloudinit|state-)/;
    push @rows,
      {
      volid => "$storeid:$volname",
      name  => $volname,
      vmid  => $1,
      size  => $lun->{ size } // 0,
      };
  }
  return \@rows;
}

sub alloc_image {
  my ( $class, $storeid, $scfg, $vmid, $fmt, $name, $size ) = @_;
  die "Error :: Unsupported format ($fmt).\n" if $fmt ne 'raw';
  if ( defined $name ) {
    die "Error :: Illegal name \"$name\".\n" if $name !~ m/^vm-$vmid-(disk-|cloudinit|state-)/;
  }
  else {
    $name = $class->find_free_diskname( $storeid, $scfg, $vmid );
  }
  $size = 1024 if $size < 1024;
  my $size_bytes = $size * 1024;

  my $loc = $scfg->{ lun_location } // '';
  die "Error :: lun_location not set.\n" if $loc eq '';
  my $lun_type = $scfg->{ lun_type } // 'ADV';

  $class->synology_ensure_target_sessions( $scfg, $storeid );
  my $t = $class->synology_resolve_target( $scfg, $storeid );
  my $target_id = $t->{ target_id };

  my $array_name = synology_array_lun_name( $scfg, $name );
  my $dev_attribs = synology_lun_create_dev_attribs($lun_type);

  my $data = synology_entry_request(
    $scfg, $storeid,
    [
      api         => 'SYNO.Core.ISCSI.LUN',
      method      => 'create',
      version     => '1',
      name        => dsm_string_param($array_name),
      size        => "$size_bytes",
      type        => $lun_type,
      location    => $loc,
      description => dsm_string_param('Proxmox VE'),
      dev_attribs => $dev_attribs,
    ],
  );
  my $uuid = $data->{ uuid } // '';
  die "Error :: Synology LUN create returned no uuid.\n" if $uuid eq '';

  synology_entry_request(
    $scfg, $storeid,
    [
      api         => 'SYNO.Core.ISCSI.LUN',
      method      => 'map_target',
      version     => '1',
      uuid        => dsm_string_param($uuid),
      target_ids  => '[' . ( 0 + $target_id ) . ']',
    ],
  );

  return $name;
}

sub free_image {
  my ( $class, $storeid, $scfg, $volname, $isBase ) = @_;
  $class->deactivate_volume( $storeid, $scfg, $volname );
  my $lun = $class->synology_find_lun_by_volname( $scfg, $volname, $storeid );
  die "Error :: Volume \"$volname\" not found for delete.\n" unless $lun;
  my $uuid = $lun->{ uuid } // '';
  die "Error :: Volume \"$volname\" has no uuid.\n" if $uuid eq '';
  synology_entry_request(
    $scfg, $storeid,
    [
      api     => 'SYNO.Core.ISCSI.LUN',
      method  => 'delete',
      version => '1',
      uuid    => dsm_string_param($uuid),
    ],
  );
  return undef;
}

sub list_images {
  my ( $class, $storeid, $scfg, $vmid, $vollist, $cache ) = @_;
  set_debug_from_config($scfg);
  if ( ref($cache) eq 'HASH' ) {
    $cache->{ synology }{ $storeid } //= $class->synology_list_volume_entries( $scfg, $storeid );
    my $all = $cache->{ synology }{ $storeid };
    if ( defined($vollist) && ref($vollist) eq 'ARRAY' ) {
      my %want = map { $_ => 1 } @$vollist;
      return [ grep { $want{ $_->{ volid } } } @$all ];
    }
    return [ grep { defined $_->{ vmid } && "$_->{vmid}" eq "$vmid" } @$all ] if defined $vmid;
    return [@$all];
  }
  my $all = $class->synology_list_volume_entries( $scfg, $storeid );
  if ( defined($vollist) && ref($vollist) eq 'ARRAY' ) {
    my %want = map { $_ => 1 } @$vollist;
    return [ grep { $want{ $_->{ volid } } } @$all ];
  }
  return [ grep { defined $_->{ vmid } && "$_->{vmid}" eq "$vmid" } @$all ] if defined $vmid;
  return $all;
}

sub status {
  my ( $class, $storeid, $scfg, $cache ) = @_;
  set_debug_from_config($scfg);
  my ( $total, $free ) = ( 1, 0 );
  eval {
    my $data = synology_entry_request(
      $scfg, $storeid,
      [
        api      => 'SYNO.Core.Storage.Volume',
        method   => 'list',
        version  => '1',
        offset   => '0',
        limit    => '-1',
        location => 'all',
      ],
    );
    my $vols = $data->{ volumes };
    # Do not use "return" here: inside eval in a sub, return exits status(), not the eval block,
    # which breaks pvesm status (undef return) when "volumes" is missing or not an array.
    if ( ref($vols) eq 'ARRAY' ) {
      my $want = $scfg->{ lun_location } // '';
      for my $v (@$vols) {
        next unless ref($v) eq 'HASH';
        my $path = $v->{ volume_path } // $v->{ path } // '';
        next if $want ne '' && $path ne '' && index( $want, $path ) != 0 && index( $path, $want ) != 0;
        my $tb = $v->{ size_total_byte } // $v->{ size } // 0;
        my $fb = $v->{ size_free_byte } // 0;
        $tb = 0 + $tb;
        $fb = 0 + $fb;
        if ( $tb > 0 ) {
          $total = $tb;
          $free  = $fb;
          last if $want ne '' && ( $path eq $want || index( $want, $path ) == 0 );
        }
      }
      if ( $total <= 1 && @$vols ) {
        my $v = $vols->[0];
        $total = 0 + ( $v->{ size_total_byte } // 0 );
        $free  = 0 + ( $v->{ size_free_byte } // 0 );
      }
    }
    1;
  } or do {
    my $err = $@;
    chomp($err);
    warn "Warning :: Synology storage \"$storeid\" status: $err\n";
    return ( 1, 0, 0, 0 );
  };
  $total = 1 if $total <= 0;
  $free = 0 if $free < 0;
  my $used = $total - $free;
  $used = 0 if $used < 0;
  return ( $total, $free, $used, 1 );
}

sub activate_storage {
  my ( $class, $storeid, $scfg, $cache ) = @_;
  set_debug_from_config($scfg);
  if ( synology_auto_iscsi_discovery_enabled($scfg) ) {
    eval {
      # Only local iscsiadm discovery/login here. Do not call synology_resolve_target (DSM Target
      # list): it is redundant for activation and can fail with iSCSI API errors (e.g. 18990xxx)
      # for some accounts or DSM builds while sendtargets/login still works.
      synology_sendtargets($scfg);
      synology_iscsi_login_all($scfg);
      1;
    } or warn "Warning :: Synology auto iSCSI for \"$storeid\": $@\n";
  }
  return 1;
}

sub deactivate_storage {
  return 1;
}

sub volume_size_info {
  my ( $class, $scfg, $storeid, $volname, $timeout ) = @_;
  my $lun = $class->synology_find_lun_by_volname( $scfg, $volname, $storeid );
  die "Error :: No volume data for \"$volname\".\n" unless $lun;
  my $size = 0 + ( $lun->{ size } // 0 );
  my $used = 0 + ( $lun->{ allocated_size } // $lun->{ used } // 0 );
  return wantarray ? ( $size, 'raw', $used, undef ) : $size;
}

sub device_op {
  my ( $device_path, $op, $value ) = @_;
  open( my $fh, '>', $device_path . '/' . $op ) or die "Error :: Could not open $device_path/$op: $!\n";
  print $fh $value;
  close($fh);
}

sub scsi_scan_new {
  my ($protocol) = @_;
  my $path = '/sys/class/' . $protocol . '_host';
  opendir( my $dh, $path ) or die "Error :: Cannot open $path: $!\n";
  my @hosts = grep { !/^\.\.?$/ } readdir($dh);
  closedir($dh);
  my $count = 0;
  for my $host (@hosts) {
    next unless $host =~ /^(\w+)$/;
    my $hp = '/sys/class/scsi_host/' . $1;
    if ( -d $hp ) {
      device_op( $hp, 'scan', '- - -' );
      ++$count;
    }
  }
  die "Error :: No SCSI hosts to scan.\n" unless $count > 0;
}

sub multipath_check {
  my ($wwid) = @_;
  return 0 unless length($wwid);
  my $out = '';
  eval {
    run_command(
      [ '/sbin/multipath', '-l', $wwid ],
      outfunc => sub { $out .= shift; },
      timeout => 15,
      quiet   => 1,
    );
  };
  return $out =~ /\S/;
}

sub wait_for {
  my ( $cb, $what, $timeout ) = @_;
  my $t0 = time();
  while (1) {
    return if $cb->();
    die "Error :: Timeout waiting for $what\n" if time() - $t0 > $timeout;
    sleep(0.2);
  }
}

sub map_volume {
  my ( $class, $storeid, $scfg, $volname, $snapname, $hints ) = @_;
  my $lun = $class->synology_find_lun_by_volname( $scfg, $volname, $storeid );
  die "Error :: Volume \"$volname\" not found.\n" unless $lun;
  my $serial_hints = synology_lun_serial_hints($lun);
  my $lid = $lun->{ lun_id };
  die "Error :: No uuid/vpd_unit_sn/lun_id for \"$volname\".\n"
    if !@$serial_hints && !( defined $lid && "$lid" =~ /^-?[0-9]+$/ );

  my $iqn_raw = $class->synology_target_iqn( $scfg, $storeid );
  my $iqn     = synology_untaint_iscsi_scalar($iqn_raw);

  my $adm = synology_iscsiadm_path();
  if ( length($iqn) && -x $adm ) {
    synology_sendtargets($scfg);
    for my $portal ( synology_discovery_portals($scfg) ) {
      my $p = synology_untaint_iscsi_scalar($portal);
      next unless length $p;
      eval {
        run_command( [ $adm, '-m', 'node', '-T', $iqn, '-p', $p, '--login' ], timeout => 45, quiet => 1 );
      };
      eval {
        run_command(
          [ $adm, '-m', 'node', '-T', $iqn, '-p', $p, '--op', 'update', '-n', 'node.startup', '-v', 'automatic' ],
          timeout => 10,
          quiet   => 1,
        );
      };
    }
    eval { run_command( [ $adm, '-m', 'session', '--rescan' ], timeout => 90, quiet => 1 ); };
  }

  eval { run_command( [ '/sbin/multipath', '-v2' ], timeout => 60, quiet => 1 ); };
  eval { scsi_scan_new('iscsi'); };
  eval { run_command( [ '/bin/udevadm', 'settle', '--timeout=30' ], timeout => 35, quiet => 1 ); };

  my $ticks = 0;
  wait_for(
    sub {
      ++$ticks;
      eval { scsi_scan_new('iscsi'); } if $ticks % 80 == 0;
      if ( $ticks % 40 == 0 ) {
        eval { run_command( [ $adm, '-m', 'session', '--rescan' ], timeout => 90, quiet => 1 ) if -x $adm; };
        eval { run_command( [ '/sbin/multipath', '-v2' ], timeout => 60, quiet => 1 ); };
      }
      my ( $p, $w ) = synology_block_path_for_lun( $class, $storeid, $scfg, $lun );
      return length($p) && -e $p;
    },
    "volume \"$volname\" (serial/lun map)",
    180,
  );

  my ( $path, $wwid ) = synology_block_path_for_lun( $class, $storeid, $scfg, $lun );
  die "Error :: Device for \"$volname\" not found.\n" unless length($path) && -b $path;
  $path = synology_untaint_dev_path($path) || $path;

  if ( length($wwid) && !multipath_check($wwid) ) {
    eval { run_command( [ '/sbin/multipathd', 'add', 'map', $wwid ], timeout => 30, quiet => 1 ); };
    wait_for( sub { multipath_check($wwid) }, "multipath $wwid", 40 );
  }
  return $path;
}

sub block_device_slaves {
  my ($path) = @_;
  my $device_path = abs_path($path);
  die "Error :: Can't resolve device path for $path\n" unless $device_path =~ m{^([/a-zA-Z0-9_\-.]+)$};
  $device_path = $1;
  my $device_name = basename($device_path);
  my $slaves_path = '/sys/block/' . $device_name . '/slaves';
  my @slaves;
  if ( -d $slaves_path ) {
    opendir( my $dh, $slaves_path ) or die "Error :: Cannot open $slaves_path: $!\n";
    @slaves = grep { !/^\.\.?$/ } readdir($dh);
    closedir($dh);
  }
  push @slaves, $device_name unless @slaves;
  return ( $device_path, @slaves );
}

sub synology_exec_command {
  my ( $command, $dm, %param ) = @_;
  $dm //= 1;
  $param{ quiet } = 1 if $DEBUG < 3 && !exists $param{ quiet };
  eval { run_command( $command, %param ); };
  if ($@) {
    my $err = " :: Cannot execute '" . join( ' ', @$command ) . "'\n  ==> $@\n";
    die 'Error' . $err if $dm > 0;
    warn 'Warning' . $err unless $dm < 0;
    return $dm < 0 ? 0 : 1;
  }
  return 1;
}

sub block_device_action {
  my ( $action, @devices ) = @_;
  for my $device (@devices) {
    next unless $device =~ /^(sd[a-z]+)$/;
    $device = $1;
    my $flush = "/dev/$device";
    $flush = $1 if $flush =~ m{^(/dev/sd[a-z]+)$};
    my $device_path = '/sys/block/' . $device . '/device';
    if ( $action eq 'remove' ) {
      synology_exec_command( [ '/sbin/blockdev', '--flushbufs', $flush ], 1, timeout => 30 );
      device_op( $device_path, 'state',  'offline' );
      device_op( $device_path, 'delete', '1' );
    }
    elsif ( $action eq 'rescan' ) {
      device_op( $device_path, 'rescan', '1' );
    }
  }
}

sub unmap_volume {
  my ( $class, $storeid, $scfg, $volname, $snapname ) = @_;
  my $lun = $class->synology_find_lun_by_volname( $scfg, $volname, $storeid );
  return 0 unless $lun;
  my ( $path, $wwid ) = synology_block_path_for_lun( $class, $storeid, $scfg, $lun );
  return 0 unless length($path) && -b $path;
  $path = synology_untaint_dev_path($path) || return 0;
  my ( $device_path, @slaves ) = eval { block_device_slaves($path) };
  return 0 if $@;
  eval { run_command( ['/bin/sync'], timeout => 30, quiet => 1 ); };
  eval { run_command( [ '/sbin/blockdev', '--flushbufs', $device_path ], timeout => 30, quiet => 1 ); };
  if ( length($wwid) && multipath_check($wwid) ) {
    eval { run_command( [ '/sbin/multipathd', 'remove', 'map', $wwid ], timeout => 30, quiet => 1 ); };
  }
  block_device_action( 'remove', @slaves );
  return 1;
}

sub activate_volume {
  my ( $class, $storeid, $scfg, $volname, $snapname, $cache, $hints ) = @_;
  $class->map_volume( $storeid, $scfg, $volname, $snapname, $hints );
  return 1;
}

sub deactivate_volume {
  my ( $class, $storeid, $scfg, $volname, $snapname, $cache ) = @_;
  $class->unmap_volume( $storeid, $scfg, $volname, $snapname );
  return 1;
}

sub volume_resize {
  my ( $class, $scfg, $storeid, $volname, $size, $running ) = @_;
  my $lun = $class->synology_find_lun_by_volname( $scfg, $volname, $storeid );
  die "Error :: volume_resize: \"$volname\" not found.\n" unless $lun;
  my $uuid = $lun->{ uuid } // '';
  die "Error :: volume_resize: no uuid.\n" if $uuid eq '';
  # PVE::Storage::volume_resize passes $size in bytes (KiB-aligned), not KiB like alloc_image.
  $size = 1024 if $size < 1024;
  synology_entry_request(
    $scfg, $storeid,
    [
      api      => 'SYNO.Core.ISCSI.LUN',
      method   => 'set',
      version  => '1',
      uuid     => dsm_string_param($uuid),
      new_size => "$size",
    ],
  );
  return 1;
}

sub rename_volume {
  my ( $class, $scfg, $storeid, $source_volname, $target_vmid, $target_volname ) = @_;
  die "Error :: rename_volume is not implemented for Synology in this plugin.\n";
}

sub synology_list_snapshots {
  my ( $class, $scfg, $storeid, $lun_uuid ) = @_;
  my $data = synology_entry_request(
    $scfg, $storeid,
    [
      api          => 'SYNO.Core.ISCSI.LUN',
      method       => 'list_snapshot',
      version      => '1',
      src_lun_uuid => dsm_string_param($lun_uuid),
    ],
  );
  my $snaps = $data->{ snapshots };
  return ref($snaps) eq 'ARRAY' ? $snaps : [];
}

sub synology_resolve_snapshot_uuid {
  my ( $class, $scfg, $storeid, $volname, $pve_snap ) = @_;
  my $lun = $class->synology_find_lun_by_volname( $scfg, $volname, $storeid );
  die "Error :: snapshot: volume \"$volname\" not found.\n" unless $lun;
  my $uuid = $lun->{ uuid } // '';
  die "Error :: snapshot: missing LUN uuid.\n" if $uuid eq '';
  my $want = synology_snapshot_dsm_name( $volname, $pve_snap );
  for my $s ( @{ $class->synology_list_snapshots( $scfg, $storeid, $uuid ) } ) {
    next unless ref($s) eq 'HASH';
    return $s->{ uuid } if ( $s->{ name } // '' ) eq $want;
  }
  die "Error :: Snapshot \"$pve_snap\" not found for \"$volname\".\n";
}

sub volume_snapshot {
  my ( $class, $scfg, $storeid, $volname, $snap ) = @_;
  my $lun = $class->synology_find_lun_by_volname( $scfg, $volname, $storeid );
  die "Error :: snapshot: volume not found.\n" unless $lun;
  my $lu = $lun->{ uuid } // '';
  my $dsm = synology_snapshot_dsm_name( $volname, $snap );
  synology_entry_request(
    $scfg, $storeid,
    [
      api             => 'SYNO.Core.ISCSI.LUN',
      method          => 'take_snapshot',
      version         => '1',
      src_lun_uuid    => dsm_string_param($lu),
      snapshot_name   => dsm_string_param($dsm),
      description     => dsm_string_param("PVE snapshot $snap"),
      taken_by        => dsm_string_param('Proxmox'),
      is_locked       => 'false',
      is_app_consistent => 'false',
    ],
  );
  return 1;
}

sub volume_snapshot_delete {
  my ( $class, $scfg, $storeid, $volname, $snap ) = @_;
  my $su = $class->synology_resolve_snapshot_uuid( $scfg, $storeid, $volname, $snap );
  synology_entry_request(
    $scfg, $storeid,
    [
      api             => 'SYNO.Core.ISCSI.LUN',
      method          => 'delete_snapshot',
      version         => '1',
      snapshot_uuid   => dsm_string_param($su),
    ],
  );
  return 1;
}

sub volume_snapshot_rollback {
  my ( $class, $scfg, $storeid, $volname, $snap ) = @_;
  my $lun = $class->synology_find_lun_by_volname( $scfg, $volname, $storeid );
  die "Error :: rollback: volume not found.\n" unless $lun;
  my $lu = $lun->{ uuid } // '';
  my $su = $class->synology_resolve_snapshot_uuid( $scfg, $storeid, $volname, $snap );
  my $api = 'SYNO.Core.ISCSI.LUN';
  my $reported = eval { synology_api_info_max_version( $scfg, $storeid, $api ); };
  undef $reported if $@;
  my $maxv;
  if ( defined $reported && "$reported" =~ /^\d+$/ && $reported >= 1 ) {
    $maxv = 0 + $reported;
    $maxv = 10 if $maxv > 10;
  }
  else {
    $maxv = 5;
  }

  my $luq = dsm_string_param($lu);
  my $suq = dsm_string_param($su);
  my @attempt_bases = (
    [ method => 'revert_snapshot', src_lun_uuid => $luq, snapshot_uuid => $suq ],
    [ method => 'revert_snapshot', uuid => $luq, snapshot_uuid => $suq ],
    [ method => 'restore_snapshot', src_lun_uuid => $luq, snapshot_uuid => $suq ],
    [ method => 'restore_snapshot', uuid => $luq, snapshot_uuid => $suq ],
    [ method => 'revert_snapshot', snapshot_uuid => $suq ],
    [ method => 'restore_snapshot', snapshot_uuid => $suq ],
  );

  my $last = '';
  for my $ver ( 1 .. $maxv ) {
    for my $ab (@attempt_bases) {
      my @params = ( api => $api, @$ab, version => "$ver" );
      my $ok = eval { synology_entry_request( $scfg, $storeid, \@params ); 1 };
      return 1 if $ok;
      $last = $@ || '';
      # 103 = method not in this API version; 104 = unsupported version or bad shape.
      die $last
        if $last !~ /\berror code\s+103\b/
        && $last !~ /\berror code\s+104\b/;
    }
  }
  if ( $last =~ /\berror code\s+103\b/ || $last =~ /\berror code\s+104\b/ ) {
    die $last
      . " In-place snapshot restore was tried for SYNO.Core.ISCSI.LUN versions 1-$maxv "
      . "with methods revert_snapshot / restore_snapshot and common parameter layouts. "
      . "Many DSM 7 SAN Manager builds do not expose this over the Web API; use DSM to "
      . "restore the LUN, or clone the snapshot to a new LUN (clone_snapshot).\n";
  }
  die $last if length $last;
  die "Error :: rollback: revert_snapshot failed.\n";
}

sub volume_rollback_is_possible {
  my ( $class, $scfg, $storeid, $volname, $snap, $blockers ) = @_;
  my $ok = eval {
    $class->synology_resolve_snapshot_uuid( $scfg, $storeid, $volname, $snap );
    1;
  };
  if ( !$ok ) {
    push @$blockers, $snap if ref($blockers) eq 'ARRAY';
    return 0;
  }
  return 1;
}

sub volume_snapshot_info {
  my ( $class, $scfg, $storeid, $volname ) = @_;
  my $lun = $class->synology_find_lun_by_volname( $scfg, $volname, $storeid );
  return {} unless $lun;
  my $lu = $lun->{ uuid } // '';
  return {} if $lu eq '';
  my %info;
  for my $s ( @{ $class->synology_list_snapshots( $scfg, $storeid, $lu ) } ) {
    next unless ref($s) eq 'HASH';
    my $desc = $s->{ description } // '';
    next unless $desc =~ /^PVE snapshot (.+)/;
    my $pve_name = $1;
    $info{ $pve_name } = { id => $s->{ uuid }, timestamp => ( $s->{ create_time } // 0 ) };
  }
  return \%info;
}

sub rename_snapshot {
  my ( $class, $scfg, $storeid, $volname, $snap, $newsnapname ) = @_;
  die "Error :: rename_snapshot is not supported.\n";
}

sub clone_image {
  my ( $class, $scfg, $storeid, $volname, $vmid, $snap ) = @_;
  my $name = $class->find_free_diskname( $storeid, $scfg, $vmid );
  my $lun = $class->synology_find_lun_by_volname( $scfg, $volname, $storeid );
  die "Error :: clone: base volume not found.\n" unless $lun;
  my $lu = $lun->{ uuid } // '';
  my $su = $class->synology_resolve_snapshot_uuid( $scfg, $storeid, $volname, $snap );
  my $array_new = synology_array_lun_name( $scfg, $name );
  my $data = synology_entry_request(
    $scfg, $storeid,
    [
      api               => 'SYNO.Core.ISCSI.LUN',
      method            => 'clone_snapshot',
      version           => '1',
      src_lun_uuid      => dsm_string_param($lu),
      snapshot_uuid     => dsm_string_param($su),
      cloned_lun_name   => dsm_string_param($array_new),
    ],
  );
  my $new_uuid = $data->{ cloned_lun_uuid } // '';
  die "Error :: clone_snapshot returned no cloned_lun_uuid.\n" if $new_uuid eq '';

  $class->synology_ensure_target_sessions( $scfg, $storeid );
  my $t         = $class->synology_resolve_target( $scfg, $storeid );
  my $target_id = $t->{ target_id };
  synology_entry_request(
    $scfg, $storeid,
    [
      api        => 'SYNO.Core.ISCSI.LUN',
      method     => 'map_target',
      version    => '1',
      uuid       => dsm_string_param($new_uuid),
      target_ids => '[' . ( 0 + $target_id ) . ']',
    ],
  );
  return $name;
}

sub volume_has_feature {
  my ( $class, $scfg, $feature, $storeid, $volname, $snapname, $running ) = @_;
  my $features = {
    copy       => { current => 1, snap => 1 },
    clone      => { current => 1, snap => 1 },
    snapshot   => { current => 1 },
    sparseinit => { current => 1 },
    rename     => { current => 0 },
  };
  my ( $vtype, $name, $vmid, $basename, $basevmid, $isBase ) = $class->parse_volname($volname);
  my $key = $snapname ? 'snap' : ( $isBase ? 'base' : 'current' );
  return 1 if $features->{ $feature } && $features->{ $feature }->{ $key };
  return undef;
}

sub volume_qemu_snapshot_method {
  my ( $class, $scfg, $storeid, $volname ) = @_;
  return 'storage';
}

sub qemu_blockdev_options {
  my ( $class, $scfg, $storeid, $volname, $machine_version, $options ) = @_;
  my $path = $class->filesystem_path( $scfg, $volname, undef, $storeid );
  return undef unless length($path) && -b $path;
  return { driver => 'host_device', filename => $path };
}

sub create_base {
  my ( $class, $storeid, $scfg, $volname ) = @_;
  die "Error :: create_base is not implemented.\n";
}

sub RAW_SIZE_HEADER_LEN {8}

sub volume_import_formats {
  my ( $class, $scfg, $storeid, $volname, $snapshot, $base_snapshot, $with_snapshots ) = @_;
  return ['raw+size'] if !$snapshot;
  return [];
}

sub volume_export_formats {
  my ( $class, $scfg, $storeid, $volname, $snapshot, $base_snapshot, $with_snapshots ) = @_;
  return ['raw+size'] if !$snapshot;
  return [];
}

sub volume_import {
  my ( $class, $scfg, $storeid, $fh, $volname, $format, $snapshot, $base_snapshot, $with_snapshots, $allow_rename ) = @_;
  die "Error :: volume_import: only raw+size.\n" if $format ne 'raw+size';
  die "Error :: volume_import: snapshot import not supported.\n" if $snapshot;

  my $hlen = RAW_SIZE_HEADER_LEN();
  my $buf;
  my $n = read( $fh, $buf, $hlen );
  die "Error :: volume_import: short read on header.\n" if !$n || $n != $hlen;
  my $size_bytes = unpack( 'Q<', $buf );
  die "Error :: volume_import: bad size.\n" if $size_bytes < 1;

  my $size_kb = int( ( $size_bytes + 1023 ) / 1024 );
  $size_kb = 1024 if $size_kb < 1024;
  my ($vmid) = $volname =~ /^vm-(\d+)-/;
  die "Error :: volume_import: invalid volname \"$volname\".\n" unless defined $vmid;
  $class->alloc_image( $storeid, $scfg, $vmid, 'raw', $volname, $size_kb );

  eval {
    $class->activate_volume( $storeid, $scfg, $volname, undef, {}, {} );
    my ( $path, undef, undef, undef ) = $class->filesystem_path( $scfg, $volname, undef, $storeid );
    die "Error :: volume_import: no device.\n" if !length($path) || !-b $path;
    open( my $dev, '>:raw', $path ) or die "Error :: cannot open $path: $!\n";
    my $chunk   = 1024 * 1024;
    my $remain  = $size_bytes;
    while ( $remain > 0 ) {
      my $to = $remain < $chunk ? $remain : $chunk;
      my $got = read( $fh, $buf, $to );
      die "Error :: volume_import: read failed.\n" if !defined $got;
      last if $got == 0;
      my $w = syswrite( $dev, $buf, $got );
      die "Error :: volume_import: write failed.\n" if !defined $w || $w != $got;
      $remain -= $got;
    }
    die "Error :: volume_import: short input.\n" if $remain > 0;
    close($dev);
    $class->deactivate_volume( $storeid, $scfg, $volname, undef, {} );
  };
  if ( my $err = $@ ) {
    eval { $class->deactivate_volume( $storeid, $scfg, $volname, undef, {} ); };
    eval { $class->free_image( $storeid, $scfg, $volname ); };
    die $err;
  }
  return "$storeid:$volname";
}

sub volume_export {
  my ( $class, $scfg, $storeid, $fh, $volname, $format, $snapshot, $base_snapshot, $with_snapshots ) = @_;
  die "Error :: volume_export: only raw+size.\n" if $format ne 'raw+size';
  die "Error :: volume_export: snapshot export not supported.\n" if $snapshot;

  my ( $size_bytes, undef, undef, undef ) = $class->volume_size_info( $scfg, $storeid, $volname, 30 );
  die "Error :: volume_export: bad size.\n" if !$size_bytes || $size_bytes < 1;

  $class->activate_volume( $storeid, $scfg, $volname, undef, {}, {} );
  eval {
    my ( $path, undef, undef, undef ) = $class->filesystem_path( $scfg, $volname, undef, $storeid );
    die "Error :: volume_export: no device.\n" if !length($path) || !-b $path;
    print $fh pack( 'Q<', $size_bytes );
    open( my $dev, '<:raw', $path ) or die "Error :: cannot open $path: $!\n";
    my $chunk = 1024 * 1024;
    my $remain = $size_bytes;
    my $buf;
    while ( $remain > 0 ) {
      my $to = $remain < $chunk ? $remain : $chunk;
      my $got = sysread( $dev, $buf, $to );
      die "Error :: volume_export: read failed.\n" if !defined $got;
      last if $got == 0;
      print $fh $buf or die "Error :: volume_export: write failed.\n";
      $remain -= $got;
    }
    die "Error :: volume_export: short read.\n" if $remain > 0;
    close($dev);
    $class->deactivate_volume( $storeid, $scfg, $volname, undef, {} );
  };
  if ( my $err = $@ ) {
    eval { $class->deactivate_volume( $storeid, $scfg, $volname, undef, {} ); };
    die $err;
  }
  return 1;
}

1;
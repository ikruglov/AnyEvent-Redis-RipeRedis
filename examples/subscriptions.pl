#!/usr/bin/perl

use 5.010000;
use strict;
use warnings;

use AnyEvent;
use AnyEvent::Redis::RipeRedis;

my $redis = AnyEvent::Redis::RipeRedis->new( {
  host => 'localhost',
  port => '6379',
  password => 'your_password',
  encoding => 'utf8',
  reconnect => 1,
  reconnect_after => 5,
  max_connect_attempts => 10,

  on_connect => sub {
    my $attempt = shift;

    say "Connected: $attempt";
  },

  on_stop_reconnect => sub {
    say 'Stop reconnecting';
  },

  on_redis_error => sub {
    my $msg = shift;

    warn "Redis error: $msg\n";
  },

  on_error => sub {
    my $msg = shift;

    warn "$msg\n";
  }
} );

my $cv = AnyEvent->condvar();


# Subscribe to channels by name

$redis->subscribe( qw( ch_1 ch_2 ), sub {
  my $ch_name = shift;
  my $msg = shift;

  say "$ch_name: $msg";

  if ( $msg eq 'unsub' ) {
    $redis->unsubscribe( qw( ch_1 ch_2 ) );
  }
} );

$redis->subscribe( qw( ch_foo ch_bar ), {
  on_subscribe =>  sub {
    my $ch_name = shift;
    my $subs_num = shift;

    say "Subscribed: $ch_name. Active: $subs_num";
  },

  on_message => sub {
    my $ch_name = shift;
    my $msg = shift;

    say "$ch_name: $msg";

    if ( $msg eq 'unsub' ) {
      $redis->unsubscribe( qw( ch_foo ch_bar ), sub {
        my $ch_name = shift;
        my $subs_num = shift;

        say "Unsubscribed: $ch_name. Active: $subs_num";

        if ( $subs_num == 0 ) {
          $cv->send();
        }
      } );
    }
  },
} );


# Subscribe to channels by pattern

$redis->psubscribe( qw( ch_* alert_* ), sub {
  my $ch_name = shift;
  my $msg = shift;
  my $ch_pattern = shift;

  say "$ch_name ($ch_pattern): $msg";

  if ( $msg eq 'unsub' ) {
    $redis->punsubscribe( qw( ch_* alert_* ) );
  }
} );

$redis->psubscribe( qw( info_* err_* ), {
  on_subscribe =>  sub {
    my $ch_pattern = shift;
    my $subs_num = shift;

    say "Subscribed: $ch_pattern. Active: $subs_num";
  },

  on_message => sub {
    my $ch_name = shift;
    my $msg = shift;
    my $ch_pattern = shift;

    say "$ch_name ($ch_pattern): $msg";

    if ( $msg eq 'unsub' ) {
      $redis->punsubscribe( qw( info_* err_* ), sub {
        my $ch_pattern = shift;
        my $subs_num = shift;

        say "Unsubscribed: $ch_pattern. Active: $subs_num";

        if ( $subs_num == 0 ) {
          $cv->send();
        }
      } );
    }
  },
} );

$cv->recv();

use 5.008000;
use strict;
use warnings;

use Test::More;
use AnyEvent::Redis::RipeRedis qw( :err_codes );
require 't/test_helper.pl';

my $SERVER_INFO = run_redis_instance();
if ( !defined( $SERVER_INFO ) ) {
  plan skip_all => 'redis-server is required for this test';
}
plan tests => 14;

my $R_CONSUM = AnyEvent::Redis::RipeRedis->new(
  host => $SERVER_INFO->{host},
  port => $SERVER_INFO->{port},
);
my $R_TRANSM = AnyEvent::Redis::RipeRedis->new(
  host => $SERVER_INFO->{host},
  port => $SERVER_INFO->{port},
);

t_sub_unsub_mth1( $R_CONSUM, $R_TRANSM );
t_sub_unsub_mth2( $R_CONSUM, $R_TRANSM );

t_psub_punsub_mth1( $R_CONSUM, $R_TRANSM );
t_psub_punsub_mth2( $R_CONSUM, $R_TRANSM );

$R_CONSUM->disconnect();
$R_TRANSM->disconnect();

t_sub_after_multi( $SERVER_INFO );


####
sub t_sub_unsub_mth1 {
  my $r_consum = shift;
  my $r_transm = shift;

  my @t_sub_data;
  my @t_sub_msgs;

  ev_loop(
    sub {
      my $cv = shift;

      my $msg_cnt = 0;

      $r_consum->subscribe( qw( ch_foo ch_bar ),
        { on_done => sub {
            my $ch_name  = shift;
            my $subs_num = shift;

            push( @t_sub_data,
              { ch_name  => $ch_name,
                subs_num => $subs_num,
              }
            );

            $r_transm->publish( $ch_name, "test$subs_num" );
          },

          on_message => sub {
            my $ch_name = shift;
            my $msg     = shift;

            push( @t_sub_msgs,
              { ch_name => $ch_name,
                message => $msg,
              }
            );

            if ( ++$msg_cnt == 2 ) {
              $cv->send();
            }
          },
        }
      );
    }
  );

  is_deeply( \@t_sub_data,
    [ { ch_name  => 'ch_foo',
        subs_num => 1,
      },
      { ch_name  => 'ch_bar',
        subs_num => 2,
      },
    ],
    'SUBSCRIBE; on_done used'
  );

  is_deeply( \@t_sub_msgs,
    [ { ch_name => 'ch_foo',
        message => 'test1',
      },
      { ch_name => 'ch_bar',
        message => 'test2',
      },
    ],
    'publish message from on_done'
  );

  my @t_unsub_data;

  ev_loop(
    sub {
      my $cv = shift;

      $r_consum->unsubscribe( qw( ch_foo ch_bar ),
        { on_done => sub {
            my $ch_name  = shift;
            my $subs_num = shift;

            push( @t_unsub_data,
              { ch_name  => $ch_name,
                subs_num => $subs_num,
              }
            );

            if ( $subs_num == 0 ) {
              $cv->send();
            }
          },
        }
      );
    }
  );

  is_deeply( \@t_unsub_data,
    [ { ch_name  => 'ch_foo',
        subs_num => 1,
      },
      { ch_name  => 'ch_bar',
        subs_num => 0,
      },
    ],
    'UNSUBSCRIBE; on_done used'
  );

  return;
}

####
sub t_sub_unsub_mth2 {
  my $r_consum = shift;
  my $r_transm = shift;

  my @t_sub_data;
  my @t_sub_msgs;

  ev_loop(
    sub {
      my $cv = shift;

      my $msg_cnt = 0;

      $r_consum->subscribe( 'ch_foo',
        sub {
          my $ch_name = shift;
          my $msg     = shift;

          push( @t_sub_msgs,
            { ch_name => $ch_name,
              message => $msg,
            }
          );

          $msg_cnt++;
        }
      );

      $r_consum->subscribe( 'ch_bar',
        { on_reply => sub {
            my $data = shift;

            if ( defined( $_[0] ) ) {
              diag( $_[0] );
              return;
            }

            push( @t_sub_data,
              { ch_name  => $data->[0],
                subs_num => $data->[1],
              }
            );

            $r_transm->publish( 'ch_foo', 'test1' );
            $r_transm->publish( $data->[0], "test$data->[1]" );
          },

          on_message => sub {
            my $ch_name = shift;
            my $msg     = shift;

            push( @t_sub_msgs,
              { ch_name => $ch_name,
                message => $msg,
              }
            );

            if ( ++$msg_cnt == 2 ) {
              $cv->send();
            }
          },
        }
      );
    }
  );

  is_deeply( \@t_sub_data,
    [ { ch_name  => 'ch_bar',
        subs_num => 2,
      },
    ],
    'SUBSCRIBE; on_reply used'
  );

  is_deeply( \@t_sub_msgs,
    [ { ch_name => 'ch_foo',
        message => 'test1',
      },
      { ch_name => 'ch_bar',
        message => 'test2',
      },
    ],
    'publish message from on_reply'
  );

  my @t_unsub_data;

  ev_loop(
    sub {
      my $cv = shift;

      $r_consum->unsubscribe( qw( ch_foo ch_bar ),
        sub {
          my $data = shift;

          if ( defined( $_[0] ) ) {
            diag( $_[0] );
            return;
          }

          push( @t_unsub_data,
            { ch_name  => $data->[0],
              subs_num => $data->[1],
            }
          );

          if ( $data->[1] == 0 ) {
            $cv->send();
          }
        }
      );
    }
  );

  is_deeply( \@t_unsub_data,
    [ { ch_name  => 'ch_foo',
        subs_num => 1,
      },
      { ch_name  => 'ch_bar',
        subs_num => 0,
      },
    ],
    'UNSUBSCRIBE; on_reply used'
  );

  return;
}

####
sub t_psub_punsub_mth1 {
  my $r_consum = shift;
  my $r_transm = shift;

  my @t_sub_data;
  my @t_sub_msgs;

  ev_loop(
    sub {
      my $cv = shift;

      my $msg_cnt = 0;

      $r_consum->psubscribe( qw( info_* err_* ),
        { on_done => sub {
            my $ch_pattern = shift;
            my $subs_num   = shift;

            push( @t_sub_data,
              { ch_pattern  => $ch_pattern,
                subs_num    => $subs_num,
              }
            );

            my $ch_name = $ch_pattern;
            $ch_name =~ s/\*/some/;
            $r_transm->publish( $ch_name, "test$subs_num" );
          },

          on_message => sub {
            my $ch_name    = shift;
            my $msg        = shift;
            my $ch_pattern = shift;

            push( @t_sub_msgs,
              { ch_name    => $ch_name,
                message    => $msg,
                ch_pattern => $ch_pattern,
              }
            );

            if ( ++$msg_cnt == 2 ) {
              $cv->send();
            }
          },
        }
      );
    }
  );

  is_deeply( \@t_sub_data,
    [ { ch_pattern => 'info_*',
        subs_num   => 1,
      },
      { ch_pattern => 'err_*',
        subs_num   => 2,
      },
    ],
    'PSUBSCRIBE; on_done used'
  );

  is_deeply( \@t_sub_msgs,
    [ { ch_name    => 'info_some',
        message    => 'test1',
        ch_pattern => 'info_*',
      },
      { ch_name    => 'err_some',
        message    => 'test2',
        ch_pattern => 'err_*',
      },
    ],
    'publish message from on_done'
  );

  my @t_unsub_data;

  ev_loop(
    sub {
      my $cv = shift;

      $r_consum->punsubscribe( qw( info_* err_* ),
        { on_done => sub {
            my $ch_pattern = shift;
            my $subs_num   = shift;

            push( @t_unsub_data,
              { ch_pattern => $ch_pattern,
                subs_num   => $subs_num,
              }
            );

            if ( $subs_num == 0 ) {
              $cv->send();
            }
          },
        }
      );
    }
  );

  is_deeply( \@t_unsub_data,
    [ { ch_pattern => 'info_*',
        subs_num   => 1,
      },
      { ch_pattern => 'err_*',
        subs_num   => 0,
      },
    ],
    'PUNSUBSCRIBE; on_done used'
  );

  return;
}

####
sub t_psub_punsub_mth2 {
  my $r_consum = shift;
  my $r_transm = shift;

  my @t_sub_data;
  my @t_sub_msgs;

  ev_loop(
    sub {
      my $cv = shift;

      my $msg_cnt = 0;

      $r_consum->psubscribe( 'info_*',
        sub {
          my $ch_name    = shift;
          my $msg        = shift;
          my $ch_pattern = shift;

          push( @t_sub_msgs,
            { ch_name    => $ch_name,
              message    => $msg,
              ch_pattern => $ch_pattern,
            }
          );

          $msg_cnt++;
        }
      );

      $r_consum->psubscribe( 'err_*',
        { on_reply => sub {
            my $data = shift;

            if ( defined( $_[0] ) ) {
              diag( $_[0] );
              return;
            }

            push( @t_sub_data,
              { ch_pattern => $data->[0],
                subs_num   => $data->[1],
              }
            );

            $r_transm->publish( 'info_some', 'test1' );

            my $ch_name = $data->[0];
            $ch_name =~ s/\*/some/;
            $r_transm->publish( $ch_name, "test$data->[1]" );
          },

          on_message => sub {
            my $ch_name    = shift;
            my $msg        = shift;
            my $ch_pattern = shift;

            push( @t_sub_msgs,
              { ch_name    => $ch_name,
                message    => $msg,
                ch_pattern => $ch_pattern,
              }
            );

            if ( ++$msg_cnt == 2 ) {
              $cv->send();
            }
          },
        }
      );
    }
  );

  is_deeply( \@t_sub_data,
    [ { ch_pattern => 'err_*',
        subs_num   => 2,
      },
    ],
    'PSUBSCRIBE; on_reply used'
  );

  is_deeply( \@t_sub_msgs,
    [ { ch_name    => 'info_some',
        message    => 'test1',
        ch_pattern => 'info_*',
      },
      { ch_name    => 'err_some',
        message    => 'test2',
        ch_pattern => 'err_*',
      },
    ],
    'publish message from on_reply'
  );

  my @t_unsub_data;

  ev_loop(
    sub {
      my $cv = shift;

      $r_consum->punsubscribe( qw( info_* err_* ),
        sub {
          my $data = shift;

          if ( defined( $_[0] ) ) {
            diag( $_[0] );
            return;
          }

          push( @t_unsub_data,
            { ch_pattern => $data->[0],
              subs_num   => $data->[1],
            }
          );

          if ( $data->[1] == 0 ) {
            $cv->send();
          }
        }
      );
    }
  );

  is_deeply( \@t_unsub_data,
    [ { ch_pattern => 'info_*',
        subs_num   => 1,
      },
      { ch_pattern => 'err_*',
        subs_num   => 0,
      },
    ],
    'PUNSUBSCRIBE; on_reply used'
  );

  return;
}

####
sub t_sub_after_multi {
  my $server_info = shift;

  my $redis = AnyEvent::Redis::RipeRedis->new(
    host => $server_info->{host},
    port => $server_info->{port},
    on_error => sub {
      # do not print this errors
    },
  );

  my $t_err_msg;
  my $t_err_code;

  ev_loop(
    sub {
      my $cv = shift;

      $redis->multi();
      $redis->subscribe( 'channel',
        { on_message => sub {
            # empty callback
          },

          on_error => sub {
            $t_err_msg = shift;
            $t_err_code = shift;

            $cv->send();
          },
        }
      );
    }
  );

  $redis->disconnect();

  my $t_name = 'subscription after MULTI command';
  is( $t_err_msg, "Command 'subscribe' not allowed"
      . " after 'multi' command. First, the transaction must be completed.",
      "$t_name; error message" );
  is( $t_err_code, E_OPRN_ERROR, "$t_name; error code" );

  return;
}

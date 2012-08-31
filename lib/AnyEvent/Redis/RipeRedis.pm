package AnyEvent::Redis::RipeRedis;

use 5.006000;
use strict;
use warnings;
use base qw( Exporter );

use fields qw(
  host
  port
  password
  connection_timeout
  reconnect
  encoding
  on_connect
  on_disconnect
  on_connect_error
  on_error

  handle
  connected
  authing
  authed
  buffer
  processing_queue
  sub_lock
  subs
);

our $VERSION = '1.103';

use AnyEvent::Handle;
use Encode qw( find_encoding is_utf8 );
use Scalar::Util qw( looks_like_number weaken );
use Carp qw( croak );

BEGIN {
  our @EXPORT_OK = qw( E_CANT_CONN E_LOADING_DATASET E_IO_OPERATION
      E_CONN_CLOSED_BY_REMOTE_HOST E_CONN_CLOSED_ON_DEMAND E_NO_CONN
      E_INVALID_PASS E_AUTH_REQUIRED E_COMMAND_EXEC E_UNEXPECTED );
  our %EXPORT_TAGS = (
    err_codes => \@EXPORT_OK,
  );
}

use constant {
  # Default values
  D_HOST => 'localhost',
  D_PORT => 6379,

  # Error codes
  E_CANT_CONN => 1,
  E_LOADING_DATASET => 2,
  E_IO_OPERATION => 3,
  E_CONN_CLOSED_BY_REMOTE_HOST => 4,
  E_CONN_CLOSED_ON_DEMAND => 5,
  E_NO_CONN => 6,
  E_INVALID_PASS => 7,
  E_AUTH_REQUIRED => 8,
  E_COMMAND_EXEC => 9,
  E_UNEXPECTED => 10,

  # String terminator
  EOL => "\r\n",
  EOL_LEN => 2,
};

my %DEFAULTS = (
  host => D_HOST,
  port => D_PORT,
);
my %SUB_ACTION_CMDS = (
  subscribe => 1,
  psubscribe => 1,
  unsubscribe => 1,
  punsubscribe => 1,
);


# Constructor
sub new {
  my $proto = shift;
  my $params = { @_ };

  my __PACKAGE__ $self = fields::new( $proto );

  $params = $self->_validate_new_params( $params );

  $self->{host} = $params->{host};
  $self->{port} = $params->{port};
  if ( defined( $params->{password} ) ) {
    $self->{password} = $params->{password};
    $self->{authed} = 0;
  }
  else {
    $self->{authed} = 1;
  }
  $self->{connection_timeout} = $params->{connection_timeout};
  $self->{reconnect} = $params->{reconnect};
  $self->{encoding} = $params->{encoding};
  $self->{on_connect} = $params->{on_connect};
  $self->{on_disconnect} = $params->{on_disconnect};
  $self->{on_connect_error} = $params->{on_connect_error};
  $self->{on_error} = $params->{on_error};
  $self->{handle} = undef;
  $self->{connected} = 0;
  $self->{authing} = 0;
  $self->{buffer} = [];
  $self->{processing_queue} = [];
  $self->{sub_lock} = 0;
  $self->{subs} = {};

  $self->_connect();

  return $self;
}

####
sub disconnect {
  my __PACKAGE__ $self = shift;

  my $was_connected = $self->{connected};
  if ( $was_connected ) {
    $self->{handle}->destroy();
    undef( $self->{handle} );
    $self->{connected} = 0;
    $self->{authing} = 0;
    $self->{authed} = 0;
  }
  $self->_abort_all( 'Connection closed on demand', E_CONN_CLOSED_ON_DEMAND );
  if ( $was_connected and defined( $self->{on_disconnect} ) ) {
    $self->{on_disconnect}->();
  }

  return;
}

####
sub _validate_new_params {
  my $params = pop;

  if (
    defined( $params->{connection_timeout} )
      and ( !looks_like_number( $params->{connection_timeout} )
        or $params->{connection_timeout} < 0 )
      ) {
    croak 'Connection timeout must be a positive number';
  }
  if ( !exists( $params->{reconnect} ) ) {
    $params->{reconnect} = 1;
  }
  if ( defined( $params->{encoding} ) ) {
    my $enc = $params->{encoding};
    $params->{encoding} = find_encoding( $enc );
    if ( !defined( $params->{encoding} ) ) {
      croak "Encoding '$enc' not found";
    }
  }
  foreach my $name (
    qw( on_connect on_disconnect on_connect_error on_error )
      ) {
    if (
      defined( $params->{$name} )
        and ref( $params->{$name} ) ne 'CODE'
        ) {
      croak "'$name' callback must be a code reference";
    }
  }

  # Set defaults
  foreach my $name ( keys( %DEFAULTS ) ) {
    if ( !defined( $params->{$name} ) ) {
      $params->{$name} = $DEFAULTS{$name};
    }
  }
  if ( !defined( $params->{on_error} ) ) {
    $params->{on_error} = sub {
      my $err_msg = shift;
      warn "$err_msg\n";
    };
  }

  return $params;
}

####
sub _connect {
  my __PACKAGE__ $self = shift;
  weaken( $self );

  $self->{handle} = AnyEvent::Handle->new(
    connect => [ $self->{host}, $self->{port} ],
    keepalive => 1,
    on_prepare => $self->_on_prepare(),
    on_connect => $self->_on_connect(),
    on_connect_error => $self->_on_conn_error(),
    on_eof => $self->_on_eof(),
    on_error => $self->_on_error(),
    on_read => $self->_on_read(
      sub {
        return $self->_prcoess_response( @_ );
      }
    ),
  );

  return;
}

####
sub _on_prepare {
  my __PACKAGE__ $self = shift;
  weaken( $self );

  return sub {
    if ( defined( $self->{connection_timeout} ) ) {
      return $self->{connection_timeout};
    }

    return;
  };
}

####
sub _on_connect {
  my __PACKAGE__ $self = shift;
  weaken( $self );

  return sub {
    $self->{connected} = 1;
    if ( defined( $self->{password} ) ) {
      $self->_auth();
    }
    else {
      $self->_flush_buffer();
    }
    if ( defined( $self->{on_connect} ) ) {
      $self->{on_connect}->();
    }
  };
}

####
sub _on_conn_error {
  my __PACKAGE__ $self = shift;
  weaken( $self );

  return sub {
    my $err_msg = pop;

    $self->{handle}->destroy();
    undef( $self->{handle} );
    $err_msg = "Can't connect to $self->{host}:$self->{port}: $err_msg";
    $self->_abort_all( $err_msg, E_CANT_CONN );
    if ( defined( $self->{on_connect_error} ) ) {
      $self->{on_connect_error}->( $err_msg );
    }
    else {
      $self->{on_error}->( $err_msg, E_CANT_CONN );
    }
  };
}

####
sub _on_eof {
  my __PACKAGE__ $self = shift;
  weaken( $self );

  return sub {
    $self->_process_error( 'Connection closed by remote host',
        E_CONN_CLOSED_BY_REMOTE_HOST );
  };
}

####
sub _on_error {
  my __PACKAGE__ $self = shift;
  weaken( $self );

  return sub {
    my $err_msg = pop;
    $self->_process_error( $err_msg, E_IO_OPERATION );
  };
}

####
sub _process_error {
  my __PACKAGE__ $self = shift;
  my $err_msg = shift;
  my $err_code = shift;

  $self->{handle}->destroy();
  undef( $self->{handle} );
  $self->{connected} = 0;
  $self->{authing} = 0;
  $self->{authed} = 0;
  $self->_abort_all( $err_msg, $err_code );
  $self->{on_error}->( $err_msg, $err_code );
  if ( defined( $self->{on_disconnect} ) ) {
    $self->{on_disconnect}->();
  }

  return;
}

####
sub _on_read {
  my __PACKAGE__ $self = shift;
  my $cb = shift;
  weaken( $self );

  my $bulk_len;

  return sub {
    my $hdl = shift;

    while ( defined( $hdl->{rbuf} ) and $hdl->{rbuf} ne '' ) {
      if ( defined( $bulk_len ) ) {
        my $bulk_eol_len = $bulk_len + EOL_LEN;
        if ( length( $hdl->{rbuf} ) < $bulk_eol_len ) {
          return;
        }
        my $data = substr( $hdl->{rbuf}, 0, $bulk_len, '' );
        substr( $hdl->{rbuf}, 0, EOL_LEN, '' );
        chomp( $data );
        if ( defined( $self->{encoding} ) ) {
          $data = $self->{encoding}->decode( $data );
        }
        undef( $bulk_len );

        return 1 if $cb->( $data );
      }
      else {
        my $eol_pos = index( $hdl->{rbuf}, EOL );
        if ( $eol_pos < 0 ) {
          return;
        }
        my $data = substr( $hdl->{rbuf}, 0, $eol_pos, '' );
        my $type = substr( $data, 0, 1, '' );
        substr( $hdl->{rbuf}, 0, EOL_LEN, '' );

        if ( $type eq '+' or $type eq ':' ) {
          return 1 if $cb->( $data );
        }
        elsif ( $type eq '-' ) {
          return 1 if $cb->( $data, 1 );
        }
        elsif ( $type eq '$' ) {
          if ( $data > 0 ) {
            $bulk_len = $data;
          }
          else {
            return 1 if $cb->();
          }
        }
        elsif ( $type eq '*' ) {
          my $m_bulk_len = $data;
          if ( $m_bulk_len > 0 ) {
            $self->_unshift_on_read( $hdl, $m_bulk_len, $cb );
            return 1;
          }
          elsif ( $m_bulk_len < 0 ) {
            return 1 if $cb->();
          }
          else {
            return 1 if $cb->( [] );
          }
        }
      }
    }
  };
}

####
sub _unshift_on_read {
  my __PACKAGE__ $self = shift;
  my $hdl = shift;
  my $m_bulk_len = shift;
  my $cb = shift;

  my $on_read;
  my @data;
  my @errors;
  my $remaining_num = $m_bulk_len;

  my $on_response = sub {
    my $data_chunk = shift;
    my $is_err = shift;

    if ( $is_err ) {
      push( @errors, $data_chunk );
    }
    else {
      push( @data, $data_chunk );
    }

    $remaining_num--;
    if (
      ref( $data_chunk ) eq 'ARRAY' and @{$data_chunk}
        and $remaining_num > 0
        ) {
      $hdl->unshift_read( $on_read );
    }
    elsif ( $remaining_num == 0 ) {
      undef( $on_read ); # Collect garbage
      if ( @errors ) {
        my $err_msg = join( "\n", @errors );
        $cb->( $err_msg, 1 );
      }
      else {
        $cb->( \@data );
      }

      return 1;
    }
  };

  $on_read = $self->_on_read( $on_response );
  $hdl->unshift_read( $on_read );

  return;
}

####
sub _prcoess_response {
  my __PACKAGE__ $self = shift;
  my $data = shift;
  my $is_err = shift;

  if ( $is_err ) {
    $self->_process_cmd_error( $data );
  }
  elsif ( %{$self->{subs}} and $self->_is_pub_message( $data ) ) {
    $self->_process_pub_message( $data );
  }
  else {
    $self->_process_data( $data );
  }

  return;
}

####
sub _process_data {
  my __PACKAGE__ $self = shift;
  my $data = shift;

  my $cmd = $self->{processing_queue}[0];
  if ( defined( $cmd ) ) {
    if ( exists( $SUB_ACTION_CMDS{$cmd->{name}} ) ) {
      $self->_process_sub_action( $cmd, $data );
      return;
    }
    shift( @{$self->{processing_queue}} );
    if ( $cmd->{name} eq 'quit' ) {
      $self->disconnect();
    }
    if ( defined( $cmd->{on_done} ) ) {
      $cmd->{on_done}->( $data );
    }
  }
  else {
    $self->{on_error}->( "Don't known how process response data."
        . ' Command queue is empty', E_UNEXPECTED );
  }

  return;
}

####
sub _process_pub_message {
  my __PACKAGE__ $self = shift;
  my $data = shift;

  if ( exists( $self->{subs}{$data->[1]} ) ) {
    my $sub = $self->{subs}{$data->[1]};
    if ( exists( $sub->{on_message} ) ) {
      if ( $data->[0] eq 'message' ) {
        $sub->{on_message}->( $data->[1], $data->[2] );
      }
      else {
        $sub->{on_message}->( $data->[2], $data->[3], $data->[1] );
      }
    }
  }
  else {
    $self->{on_error}->( "Don't known how process published message."
        . " Unknown channel or pattern '$data->[1]'", E_UNEXPECTED );
  }

  return;
}

####
sub _process_cmd_error {
  my __PACKAGE__ $self = shift;
  my $err_msg = shift;

  my $cmd = shift( @{$self->{processing_queue}} );
  if ( defined( $cmd ) ) {
    my $err_code;
    if ( index( $err_msg, 'LOADING' ) == 0 ) {
      $err_code = E_LOADING_DATASET;
    }
    elsif ( $err_msg eq 'ERR invalid password' ) {
      $err_code = E_INVALID_PASS;
    }
    elsif ( $err_msg eq 'ERR operation not permitted' ) {
      $err_code = E_AUTH_REQUIRED;
    }
    else {
      $err_code = E_COMMAND_EXEC;
    }
    $cmd->{on_error}->( $err_msg, $err_code );
  }
  else {
    $self->{on_error}->( "Don't known how process error message '$err_msg'."
        . " Command queue is empty", E_UNEXPECTED );
  }

  return;
}

####
sub _process_sub_action {
  my __PACKAGE__ $self = shift;
  my $cmd = shift;
  my $data = shift;

  if ( $cmd->{name} eq 'subscribe' or $cmd->{name} eq 'psubscribe' ) {
    my $sub = {};
    if ( defined( $cmd->{on_done} ) ) {
      $sub->{on_done} = $cmd->{on_done};
      $sub->{on_done}->( $data->[1], $data->[2] );
    }
    if ( defined( $cmd->{on_message} ) ) {
      $sub->{on_message} = $cmd->{on_message};
    }
    $self->{subs}{$data->[1]} = $sub;
  }
  else {
    if ( defined( $cmd->{on_done} ) ) {
      $cmd->{on_done}->( $data->[1], $data->[2] );
    }
    if ( exists( $self->{subs}{$data->[1]} ) ) {
      delete( $self->{subs}{$data->[1]} );
    }
  }

  if ( --$cmd->{resp_remaining} == 0 ) {
    shift( @{$self->{processing_queue}} );
  }

  return;
}

####
sub _is_pub_message {
  my $data = pop;

  return ( ref( $data ) eq 'ARRAY' and ( $data->[0] eq 'message'
      or $data->[0] eq 'pmessage' ) );
}

####
sub _exec_command {
  my __PACKAGE__ $self = shift;
  my $cmd_name = shift;
  my @args = @_;
  my $params = {};
  if ( ref( $args[-1] ) eq 'HASH' ) {
    $params = pop( @args );
  }

  $params = $self->_validate_exec_params( $params );

  my $cmd = {
    name => $cmd_name,
    args => \@args,
    %{$params},
  };

  if ( exists( $SUB_ACTION_CMDS{$cmd->{name}} ) ) {
    if ( $self->{sub_lock} ) {
      $cmd->{on_error}->( "Command '$cmd->{name}' not allowed after 'multi' command."
          . ' First, the transaction must be completed', E_COMMAND_EXEC );
      return;
    }
    $cmd->{resp_remaining} = scalar( @{$cmd->{args}} );
  }
  elsif ( $cmd->{name} eq 'multi' ) {
    $self->{sub_lock} = 1;
  }
  elsif ( $cmd->{name} eq 'exec' ) {
    $self->{sub_lock} = 0;
  }

  if ( !defined( $self->{handle} ) ) {
    if ( $self->{reconnect} ) {
      $self->_connect();
    }
    else {
      $cmd->{on_error}->( "Can't handle the command '$cmd->{name}'."
          . ' No connection to the server', E_NO_CONN );
      return;
    }
  }
  if ( $self->{connected} ) {
    if ( $self->{authed} ) {
      $self->_push_to_handle( $cmd );
    }
    else {
      if ( !$self->{authing} ) {
        $self->_auth();
      }
      push( @{$self->{buffer}}, $cmd );
    }
  }
  else {
    push( @{$self->{buffer}}, $cmd );
  }

  return;
}

####
sub _validate_exec_params {
  my __PACKAGE__ $self = shift;
  my $params = shift;

  foreach my $name ( qw( on_done on_message on_error ) ) {
    if (
      defined( $params->{$name} )
        and ref( $params->{$name} ) ne 'CODE'
        ) {
      croak "'$name' callback must be a code reference";
    }
  }

  if ( !defined( $params->{on_error} ) ) {
    $params->{on_error} = $self->{on_error};
  }

  return $params;
}

####
sub _auth {
  my __PACKAGE__ $self = shift;

  $self->{authing} = 1;
  $self->_push_to_handle( {
    name => 'auth',
    args => [ $self->{password} ],
    on_done => sub {
      $self->{authing} = 0;
      $self->{authed} = 1;
      $self->_flush_buffer();
    },

    on_error => sub {
      my $err_msg = shift;
      my $err_code = shift;

      $self->{authing} = 0;
      $self->_abort_all( $err_msg, $err_code );
      $self->{on_error}->( $err_msg, $err_code );
    },
  } );

  return;
}

####
sub _flush_buffer {
  my __PACKAGE__ $self = shift;

  my @commands = @{$self->{buffer}};
  $self->{buffer} = [];
  foreach my $cmd ( @commands ) {
    $self->_push_to_handle( $cmd );
  }

  return;
}

####
sub _push_to_handle {
  my __PACKAGE__ $self = shift;
  my $cmd = shift;

  push( @{$self->{processing_queue}}, $cmd );
  my $cmd_str = '';
  my $m_bulk_len = 0;
  foreach my $token ( $cmd->{name}, @{$cmd->{args}} ) {
    if ( defined( $token ) and $token ne '' ) {
      if ( defined( $self->{encoding} ) and is_utf8( $token ) ) {
        $token = $self->{encoding}->encode( $token );
      }
      my $token_len = length( $token );
      $cmd_str .= "\$$token_len" . EOL . $token . EOL;
      ++$m_bulk_len;
    }
  }
  $cmd_str = "*$m_bulk_len" . EOL . $cmd_str;
  $self->{handle}->push_write( $cmd_str );

  return;
}

####
sub _abort_all {
  my __PACKAGE__ $self = shift;
  my $err_msg = shift;
  my $err_code = shift;

  $self->{sub_lock} = 0;
  $self->{subs} = {};
  my @commands;
  if ( defined( $self->{buffer} ) and @{$self->{buffer}} ) {
    @commands =  @{$self->{buffer}};
    $self->{buffer} = [];
  }
  elsif (
    defined( $self->{processing_queue} )
      and @{$self->{processing_queue}}
      ) {
    @commands =  @{$self->{processing_queue}};
    $self->{processing_queue} = [];
  }
  foreach my $cmd ( @commands ) {
    $cmd->{on_error}->( "Command '$cmd->{name}' aborted: $err_msg", $err_code );
  }

  return;
}

####
sub AUTOLOAD {
  our $AUTOLOAD;
  my $cmd_name = $AUTOLOAD;
  $cmd_name =~ s/^.+:://o;
  $cmd_name = lc( $cmd_name );

  my $sub = sub {
    my __PACKAGE__ $self = shift;
    $self->_exec_command( $cmd_name, @_ );
  };

  do {
    no strict 'refs';
    *{$AUTOLOAD} = $sub;
  };

  goto &{$sub};
}

####
sub DESTROY {}

1;
__END__

=head1 NAME

AnyEvent::Redis::RipeRedis - Non-blocking Redis client with reconnection feature

=head1 SYNOPSIS

  use AnyEvent;
  use AnyEvent::Redis::RipeRedis qw( :err_codes );

  my $cv = AnyEvent->condvar();

  my $redis = AnyEvent::Redis::RipeRedis->new(
    host => 'localhost',
    port => '6379',
    password => 'your_password',
    encoding => 'utf8',

    on_connect => sub {
      print "Connected to Redis server\n";
    },

    on_disconnect => sub {
      print "Disconnected from Redis server\n";
    },

    on_error => sub {
      my $err_msg = shift;
      my $err_code = shift;
      warn "$err_msg. Error code: $err_code\n";
    },
  );

  # Set value
  $redis->set( 'bar', 'Some string', {
    on_done => sub {
      my $data = shift;
      print "$data\n";
    },

    on_error => sub {
      my $err_msg = shift;
      my $err_code = shift;

      warn "$err_msg. Error code: $err_code\n";
      if ( $err_code == E_LOADING_DATASET ) {
        # Do something special
      }
    }
  } );

  $cv->recv();

  $redis->disconnect();

=head1 DESCRIPTION

AnyEvent::Redis::RipeRedis is a non-blocking Redis client with with reconnection
feature. It supports subscriptions, transactions, has simple API and it faster
than AnyEvent::Redis.

Requires Redis 1.2 or higher and any supported event loop.

=head1 CONSTRUCTOR

  my $redis = AnyEvent::Redis::RipeRedis->new(
    host => 'localhost',
    port => '6379',
    password => 'your_password',
    connection_timeout => 5,
    reconnect => 1,
    encoding => 'utf8',

    on_connect => sub {
      print "Connected to Redis server\n";
    },

    on_disconnect => sub {
      print "Disconnected from Redis server\n";
    },

    on_connect_error => sub {
      my $err_msg = shift;
      warn "$err_msg\n";
    },

    on_error => sub {
      my $err_msg = shift;
      my $err_code = shift;
      warn "$err_msg. Error code: $err_code\n";
    },
  );

=head2 Constructor parameters

=over

=item host

Server hostname (default: 127.0.0.1)

=item port

Server port (default: 6379)

=item password

Authentication password. If it specified, C<AUTH> command will be executed
automaticaly.

=item connection_timeout

Connection timeout. If after this timeout client could not connect to the server,
callback C<on_error> is called.

=item reconnect

If this parameter is TRUE (TRUE by default), client in case of lost connection
will attempt to reconnect to server, when executing next command. Client will
attempt to reconnect only once and if it fails, calls C<on_error> callback. If
you need several attempts of reconnection, just retry command from C<on_error>
callback as many times, as you need. This feature made client more responsive.

=item encoding

Used to decode and encode strings during read and write operations.

=item on_connect => $cb->()

Callback C<on_connect> is called, when connection is established.

=item on_disconnect => $cb->()

Callback C<on_disconnect> is called, when connection is closed.

=item on_connect_error => $cb->( $err_msg )

Callback C<on_connect_error> is called, when the connection could not be established.
If this collback isn't specified, then C<on_error> callback is called.

=item on_error => $cb->( $err_msg, $err_code )

Callback C<on_error> is called, when any error occurred.

=back

=head1 COMMAND EXECUTION

=head2 <command>( [ @args[, \%params ] ] )

  # Increment
  $redis->incr( 'foo', {
    on_done => sub {
      my $data = shift;
      print "$data\n";
    },
  } );

  # Set value
  $redis->set( 'bar', 'Some string' );

  # Get list of values
  $redis->lrange( 'list', 0, -1, {
    on_done => sub {
      my $data = shift;
      foreach my $val ( @{ $data } ) {
        print "$val\n";
      }
    },

    on_error => sub {
      my $err_msg = shift;
      my $err_code = shift;
      warn "$err_msg. Error code: $err_code\n";
    },
  } );

Full list of Redis commands can be found here: L<http://redis.io/commands>

=over

=item on_done => $cb->( $data )

Callback C<on_done> is called, when command handling is done.

=item on_error => $cb->( $err_msg, $err_code )

Callback C<on_error> is called, when any error occurred.

=back

=head1 SUBSCRIPTIONS

=head2 subscribe( @channels[, \%params ] )

Subscribe to channels by name:

  $redis->subscribe( qw( ch_foo ch_bar ), {
    on_done =>  sub {
      my $ch_name = shift;
      my $subs_num = shift;
      print "Subscribed: $ch_name. Active: $subs_num\n";
    },

    on_message => sub {
      my $ch_name = shift;
      my $msg = shift;
      print "$ch_name: $msg\n";
    },
  } );

=over

=item on_done => $cb->( $ch_name, $sub_num )

Callback C<on_done> is called, when subscription is done.

=item on_message => $cb->( $ch_name, $msg )

Callback C<on_message> is called, when published message is received.

=item on_error => $cb->( $err_msg, $err_code )

Callback C<on_error> is called, when any error occurred.

=back

=head2 psubscribe( @patterns[, \%params ] )

Subscribe to group of channels by pattern:

  $redis->psubscribe( qw( info_* err_* ), {
    on_done =>  sub {
      my $ch_pattern = shift;
      my $subs_num = shift;
      print "Subscribed: $ch_pattern. Active: $subs_num\n";
    },

    on_message => sub {
      my $ch_name = shift;
      my $msg = shift;
      my $ch_pattern = shift;
      print "$ch_name ($ch_pattern): $msg\n";
    },

    on_error => sub {
      my $err_msg = shift;
      warn "$err_msg\n";
    },
  } );

=over

=item on_done => $cb->( $ch_pattern, $sub_num )

Callback C<on_done> is called, when subscription is done.

=item on_message => $cb->( $ch_name, $msg, $ch_pattern )

Callback C<on_message> is called, when published message is received.

=item on_error => $cb->( $err_msg, $err_code )

Callback C<on_error> is called, when any error occurred.

=back


=head2 unsubscribe( @channels[, \%params ] )

Unsubscribe from channels by name:

  $redis->unsubscribe( qw( ch_foo ch_bar ), {
    on_done => sub {
      my $ch_name = shift;
      my $subs_num = shift;
      print "Unsubscribed: $ch_name. Active: $subs_num\n";
    },

    on_error => sub {
      my $err_msg = shift;
      warn "$err_msg\n";
    },
  } );

=over

=item on_done => $cb->( $ch_name, $sub_num )

Callback C<on_done> is called, when unsubscription is done.

=item on_error => $cb->( $err_msg, $err_code )

Callback C<on_error> is called, when any error occurred.

=back

=head2 punsubscribe( @patterns[, \%params ] )

Unsubscribe from group of channels by pattern:

  $redis->punsubscribe( qw( info_* err_* ), {
    on_done => sub {
      my $ch_pattern = shift;
      my $subs_num = shift;
      print "Unsubscribed: $ch_pattern. Active: $subs_num\n";
    },

    on_error => sub {
      my $err_msg = shift;
      warn "$err_msg\n";
    },
  } );

=over

=item on_done => $cb->( $ch_pattern, $sub_num )

Callback C<on_done> is called, when unsubscription is done.

=item on_error => $cb->( $err_msg, $err_code )

Callback C<on_error> is called, when any error occurred.

=back


=head1 CONNECTION VIA UNIX-SOCKET

Redis 2.2 and higher support connection via UNIX domain socket. To connect via
a UNIX-socket in the parameter C<host> you have to specify C<unix/>, and in
the parameter C<port> you have to specify the path to the socket.

  my $redis = AnyEvent::Redis::RipeRedis->new(
    host => 'unix/',
    port => '/tmp/redis.sock',
  );

=head1 ERROR CODES

Error codes were introduced in version of module 1.100. They can be used for
programmatic handling of errors.

  1  - E_CANT_CONN
  2  - E_LOADING_DATASET
  3  - E_IO_OPERATION
  4  - E_CONN_CLOSED_BY_REMOTE_HOST
  5  - E_CONN_CLOSED_ON_DEMAND
  6  - E_NO_CONN
  7  - E_INVALID_PASS
  8  - E_AUTH_REQUIRED
  9  - E_COMMAND_EXEC
  10 - E_UNEXPECTED

=over

=item E_CANT_CONN

Can't connect to server.

=item E_LOADING_DATASET

Redis is loading the dataset in memory.

=item E_IO_OPERATION

I/O operation error.

=item E_CONN_CLOSED_BY_REMOTE_HOST

Connection closed by remote host.

=item E_CONN_CLOSED_ON_DEMAND

Connection closed on demand.

=item E_NO_CONN

No connection to the server.

=item E_INVALID_PASS

Invalid password

=item E_AUTH_REQUIRED

Operation not permitted. Authentication required.

=item E_COMMAND_EXEC

Command execution error.

=item E_UNEXPECTED

Unexpected error.

=back

To use constants of error codes you have to import them.

  use AnyEvent::Redis::RipeRedis qw( :err_codes );

=head1 DISCONNECTION

When the connection to the server is no longer needed you can close it in three
ways: send C<QUIT> command, call method C<disconnect()>, or you can just "forget"
any references to an AnyEvent::Redis::RipeRedis object, but in this case client
don't calls C<on_disconnect> callback.

  $redis->quit(
    on_done => sub {
      # Do something
    }
  } );

  $redis->disconnect();

  undef( $redis );

=head1 SEE ALSO

L<AnyEvent>, L<AnyEvent::Redis>, L<Redis>

=head1 AUTHOR

Eugene Ponizovsky, E<lt>ponizovsky@gmail.comE<gt>

=head2 Special thanks

=over

=item *

Alexey Shrub

=item *

Vadim Vlasov

=item *

Konstantin Uvarin

=back

=head1 COPYRIGHT AND LICENSE

Copyright (c) 2012, Eugene Ponizovsky, E<lt>ponizovsky@gmail.comE<gt>. All rights
reserved.

This module is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

=cut

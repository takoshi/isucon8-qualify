package Torb::Web;
use strict;
use warnings;
use utf8;

use Kossy;

use JSON::XS 3.00;
use JSON::Types;

use DBIx::Sunny;
use Plack::Session;
use Time::Moment;

filter login_required => sub {
    my $app = shift;
    return sub {
        my ($self, $c) = @_;
        my $session = Plack::Session->new($c->env);

        my $user_id = $session->get('user_id');
        my $user = $self->get_user($user_id);
        unless ($user) {
            my $res = $c->render_json({
                error => 'login_required',
            });
            $res->status(401);
            return $res;
        }

        $app->($self, $c);
    };
};

filter fillin_user => sub {
    my $app = shift;
    return sub {
        my ($self, $c) = @_;
        my $session = Plack::Session->new($c->env);

        if (my $user_id = $session->get('user_id')) {
            my $user = $self->get_user($user_id);
            $c->stash->{user} = $user;
        }

        $app->($self, $c);
    };
};

sub dbh {
    my $self = shift;
    $self->{_dbh} ||= do {
        my $dsn = "dbi:mysql:database=$ENV{DB_DATABASE};host=$ENV{DB_HOST};port=$ENV{DB_PORT}";
        DBIx::Sunny->connect($dsn, $ENV{DB_USER}, $ENV{DB_PASS}, {
            mysql_enable_utf8mb4 => 1,
            mysql_auto_reconnect => 1,
        });
    };
}

get '/' => [qw/fillin_user/] => sub {
    my ($self, $c) = @_;
    return $c->render('index.tx');
};

post '/api/users' => sub {
    my ($self, $c) = @_;
    my $nickname   = $c->req->body_parameters->get('nickname');
    my $login_name = $c->req->body_parameters->get('login_name');
    my $password   = $c->req->body_parameters->get('password');

    my ($user_id, $error);

    my $txn = $self->dbh->txn_scope();
    eval {
        my $duplicated = $self->dbh->select_one('SELECT * FROM users WHERE login_name = ?', $login_name);
        if ($duplicated) {
            $error = 'duplicated';
            $txn->rollback();
            return;
        }

        $self->dbh->query('INSERT INTO users (login_name, pass_hash, nickname) VALUES (?, SHA2(?, 256), ?)', $login_name, $password, $nickname);
        $user_id = $self->dbh->last_insert_id();
        $txn->commit();
    };
    if ($@) {
        $txn->rollback();
        warn "rollback by: $@";
        $error = 'unknown';
    }

    if ($error) {
        my $res = $c->render_json({
            error => $error,
        });
        $res->status(500);
        $res->status(409) if $error eq 'duplicated';
        return $res;
    }

    my $user = $self->get_user($user_id);
    my $res = $c->render_json($user);
    $res->status(201);
    return $res;
};

sub get_user {
    my ($self, $user_id) = @_;
    my $user = $self->dbh->select_row('SELECT * FROM users WHERE id = ?', $user_id);
    delete $user->{login_name};
    delete $user->{pass_hash};
    return $user;
}

sub get_login_user {
    my ($self, $c) = @_;

    my $session = Plack::Session->new($c->env);
    my $user_id = $session->get('user_id');
    return $self->get_user($user_id);
}

post '/api/actions/login' => sub {
    my ($self, $c) = @_;
    my $login_name = $c->req->body_parameters->get('login_name');
    my $password   = $c->req->body_parameters->get('password');

    my $user      = $self->dbh->select_row('SELECT * FROM users WHERE login_name = ?', $login_name);
    my $pass_hash = $self->dbh->select_one('SELECT SHA2(?, 256)', $password);
    if ($pass_hash ne $user->{pass_hash}) {
        my $res = $c->render_json({
            error => 'authentication_failed',
        });
        $res->status(401);
        return $res;
    }

    my $session = Plack::Session->new($c->env);
    $session->set('user_id' => $user->{id});
    return $c->req->new_response(204, [], '');
};

post '/api/actions/logout' => [qw/login_required/] => sub {
    my ($self, $c) = @_;
    my $session = Plack::Session->new($c->env);
    $session->remove('user_id');
    return $c->req->new_response(204, [], '');
};

get '/api/events' => sub {
    my ($self, $c) = @_;

    my @events;
    my @event_ids = map { $_->{id} } @{ $self->dbh->select_all('SELECT id FROM events') };
    for my $event_id (@event_ids) {
        my $event = $self->get_event($event_id);
        next unless $event->{public_fg};

        delete $event->{sheets}->{detail};
        push @events => $self->sanitize_event($event);
    }

    return $c->render_json(\@events);
};

get '/api/events/{id}' => sub {
    my ($self, $c) = @_;
    my $event_id = $c->args->{id};

    my $user = $self->get_login_user($c);
    my $event = $self->get_event($event_id, $user->{id});
    if (!$event || !$event->{public_fg}) {
        my $res = $c->render_json({
            error => 'not_found',
        });
        $res->status(404);
        return $res;
    }

    $event = $self->sanitize_event($event);
    return $c->render_json($event);
};

sub get_event {
    my ($self, $event_id, $login_user_id) = @_;

    my $event = $self->dbh->select_row('SELECT * FROM events WHERE id = ?', $event_id);
    return unless $event;

    my $sheets = $self->dbh->select_all('SELECT * FROM sheets ORDER BY `rank`, num');
    for my $sheet (@$sheets) {
        $event->{sheets}->{price}->{$sheet->{rank}} ||= $event->{price} + $sheet->{price};

        $event->{sheets}->{total}->{all} += 1;
        $event->{sheets}->{total}->{$sheet->{rank}} += 1;

        my $reservation = $self->dbh->select_row('SELECT * FROM reservations WHERE event_id = ? AND sheet_id = ?', $event->{id}, $sheet->{id});
        if ($reservation) {
            $sheet->{reserved}    = 1;
            $sheet->{reserved_at} = $reservation->{reserved_at};
            $sheet->{is_mine}     = 1 if $login_user_id && $reservation->{user_id} == $login_user_id;
        } else {
            $event->{sheets}->{remains}->{all} += 1;
            $event->{sheets}->{remains}->{$sheet->{rank}} += 1;
        }

        delete $sheet->{id};
        delete $sheet->{price};

        push @{ $event->{sheets}->{detail}->{$sheet->{rank}} } => $sheet;
    }

    return $event;
}

sub sanitize_event {
    my ($self, $event) = @_;
    my $sanitized = {%$event}; # shallow clone
    delete $sanitized->{price};
    delete $sanitized->{public_fg};
    return $sanitized;
}

post '/api/events/{id}/actions/reserve' => [qw/login_required/] => sub {
    my ($self, $c) = @_;
    my $event_id = $c->args->{id};
    my $rank = $c->req->body_parameters->get('sheet_rank');

    my $user  = $self->get_login_user($c);
    my $event = $self->get_event($event_id, $user->{id});

    my $sheet;
    while (1) {
        $sheet = $self->dbh->select_row('SELECT * FROM sheets WHERE id NOT IN (SELECT sheet_id FROM reservations WHERE event_id = ?) AND `rank` = ? ORDER BY RAND() LIMIT 1', $event->{id}, $rank);
        unless ($sheet) {
            my $res = $c->render_json({
                error => 'sold_out',
            });
            $res->status(409);
            return $res;
        }

        my $txn = $self->dbh->txn_scope();
        eval {
            $self->dbh->query('INSERT INTO reservations (event_id, sheet_id, user_id, reserved_at) VALUES (?, ?, ?, CURRENT_TIMESTAMP)', $event->{id}, $sheet->{id}, $user->{id});
            $txn->commit();
        };
        if ($@) {
            $txn->rollback();
            next; # retry
        }
    }

    my $res = $c->render_json({
        sheet_rank => $rank,
        sheet_num => $sheet->{num},
    });
    $res->status(202);
    return $res;
};

router ['DELETE'] => '/api/events/{id}/sheets/{rank}/{num}/reservation' => [qw/login_required/] => sub {
    my ($self, $c) = @_;
    my $event_id = $c->args->{id};
    my $rank     = $c->args->{rank};
    my $num      = $c->args->{num};

    my $user  = $self->get_login_user($c);
    my $event = $self->get_event($event_id, $user->{id});

    my $error;

    my $txn = $self->dbh->txn_scope();
    eval {
        my $sheet = $self->dbh->select_row('SELECT * FROM sheets WHERE `rank` = ? AND num = ?', $rank, $num);
        unless ($sheet) {
            $error = 'invalid_sheet';
            $txn->rollback();
            return;
        }

        my $reservation = $self->dbh->select_row('SELECT * FROM reservations WHERE event_id = ? AND sheet_id = ?', $event->{id}, $sheet->{id});
        unless ($reservation) {
            $error = 'not_reserved';
            $txn->rollback();
            return;
        }
        if ($reservation->{user_id} != $user->{id}) {
            $error = 'not_permitted';
            $txn->rollback();
            return;
        }

        $self->dbh->query('DELETE FROM reservations WHERE event_id = ? AND sheet_id = ? AND user_id = ?', $event->{id}, $sheet->{id}, $user->{id});
        $txn->commit();
    };
    if ($@) {
        $txn->rollback();
        $error = 'unknown';
        warn "rollback by: $@";
    }

    if ($error) {
        my $res = $c->render_json({
            error => $error,
        });
        $res->status(500);
        $res->status(404) if $error eq 'invalid_sheet';
        $res->status(400) if $error eq 'not_reserved';
        $res->status(403) if $error eq 'not_permitted';
        return $res;
    }

    return $c->req->new_response(204, [], '');
};

filter admin_login_required => sub {
    my $app = shift;
    return sub {
        my ($self, $c) = @_;
        my $session = Plack::Session->new($c->env);

        my $administrator_id = $session->get('administrator_id');
        my $administrator = $self->get_administrator($administrator_id);
        unless ($administrator) {
            my $res = $c->render_json({
                error => 'login_required',
            });
            $res->status(401);
            return $res;
        }

        $app->($self, $c);
    };
};

filter fillin_administrator => sub {
    my $app = shift;
    return sub {
        my ($self, $c) = @_;
        my $session = Plack::Session->new($c->env);

        if (my $administrator_id = $session->get('administrator_id')) {
            my $administrator = $self->get_administrator($administrator_id);
            $c->stash->{administrator} = $administrator;
        }

        $app->($self, $c);
    };
};

get '/admin/' => [qw/fillin_administrator/] => sub {
    my ($self, $c) = @_;
    return $c->render('admin.tx');
};

post '/admin/api/actions/login' => sub {
    my ($self, $c) = @_;
    my $login_name = $c->req->body_parameters->get('login_name');
    my $password   = $c->req->body_parameters->get('password');

    my $administrator = $self->dbh->select_row('SELECT * FROM administrators WHERE login_name = ?', $login_name);
    my $pass_hash     = $self->dbh->select_one('SELECT SHA2(?, 256)', $password);
    if ($pass_hash ne ($administrator->{pass_hash}||'')) {
        my $res = $c->render_json({
            error => 'authentication_failed',
        });
        $res->status(401);
        return $res;
    }

    my $session = Plack::Session->new($c->env);
    $session->set('administrator_id' => $administrator->{id});
    return $c->req->new_response(204, [], '');
};

post '/admin/api/actions/logout' => [qw/admin_login_required/] => sub {
    my ($self, $c) = @_;
    my $session = Plack::Session->new($c->env);
    $session->remove('administrator_id');
    return $c->req->new_response(204, [], '');
};

sub get_administrator {
    my ($self, $administrator_id) = @_;
    my $administrator = $self->dbh->select_row('SELECT * FROM administrators WHERE id = ?', $administrator_id);
    delete $administrator->{login_name};
    delete $administrator->{pass_hash};
    return $administrator;
}

sub get_login_administrator {
    my ($self, $c) = @_;

    my $session = Plack::Session->new($c->env);
    my $administrator_id = $session->get('administrator_id');
    return $self->get_administrator($administrator_id);
}

get '/admin/api/events' => [qw/admin_login_required/] => sub {
    my ($self, $c) = @_;

    my @events;
    my @event_ids = map { $_->{id} } @{ $self->dbh->select_all('SELECT id FROM events') };
    for my $event_id (@event_ids) {
        my $event = $self->get_event($event_id);
        delete $event->{sheets}->{detail};
        $event->{public} = delete $event->{public_fg} ? JSON::XS::true : JSON::XS::false;
        push @events => $event;
    }

    return $c->render_json(\@events);
};

post '/admin/api/events' => [qw/admin_login_required/] => sub {
    my ($self, $c) = @_;
    my $title  = $c->req->body_parameters->get('title');
    my $public = $c->req->body_parameters->get('public') ? 1 : 0;
    my $price  = $c->req->body_parameters->get('price');

    my $event_id;

    my $txn = $self->dbh->txn_scope();
    eval {
        $self->dbh->query('INSERT INTO events (title, public_fg, price) VALUES (?, ?, ?)', $title, $public, $price);
        $event_id = $self->dbh->last_insert_id();
        $txn->commit();
    };
    if ($@) {
        $txn->rollback();
    }

    my $event = $self->get_event($event_id);
    return $c->render_json($event);
};

get '/admin/api/events/{id}' => [qw/admin_login_required/] => sub {
    my ($self, $c) = @_;
    my $event_id = $c->args->{id};

    my $event = $self->get_event($event_id);
    unless ($event) {
        my $res = $c->render_json({
            error => 'not_found',
        });
        $res->status(404);
        return $res;
    }

    $event->{public} = delete $event->{public_fg} ? JSON::XS::true : JSON::XS::false;
    return $c->render_json($event);
};

post '/admin/api/events/{id}/actions/edit' => [qw/admin_login_required/] => sub {
    my ($self, $c) = @_;
    my $event_id = $c->args->{id};
    my $title  = $c->req->body_parameters->get('title');
    my $public = $c->req->body_parameters->get('public') ? 1 : 0;
    my $price  = $c->req->body_parameters->get('price');

    my $event = $self->get_event($event_id);
    unless ($event) {
        my $res = $c->render_json({
            error => 'not_found',
        });
        $res->status(404);
        return $res;
    }

    my $txn = $self->dbh->txn_scope();
    eval {
        $self->dbh->query('UPDATE events SET title = ?, public_fg = ?, price = ? WHERE id = ?', $title, $public, $price, $event->{id});
        $txn->commit();
    };
    if ($@) {
        $txn->rollback();
    }

    $event = $self->get_event($event_id);
    $event->{public} = delete $event->{public_fg} ? JSON::XS::true : JSON::XS::false;
    return $c->render_json($event);
};

get '/admin/api/reports/events/{id}/sales' => [qw/admin_login_required/] => sub {
    my ($self, $c) = @_;
    my $event_id = $c->args->{id};
    my $event = $self->get_event($event_id);

    my @reports;
    for my $sheet (map { @$_ } values %{ $event->{sheets}->{detail} }) {
        next unless $sheet->{reserved};

        my $report = {
            event_id => $event->{id},
            sold_at  => Time::Moment->from_epoch($sheet->{reserved_at}, 0)->as_string,
            price    => $event->{sheets}->{price}->{$sheet->{rank}},
        };
        push @reports => $report;
    }

    return $self->render_report_csv($c, \@reports);
};

get '/admin/api/reports/sales' => [qw/admin_login_required/] => sub {
    my ($self, $c) = @_;
    my $event_id = $c->args->{id};
    my $event = $self->get_event($event_id);

    my @reports;

    my @event_ids = map { $_->{id} } @{ $self->dbh->select_all('SELECT id FROM events') };
    for my $event_id (@event_ids) {
        my $event = $self->get_event($event_id);
        for my $sheet (map { @$_ } values %{ $event->{sheets}->{detail} }) {
            next unless $sheet->{reserved};

            my $report = {
                event_id => $event->{id},
                sold_at  => Time::Moment->from_epoch($sheet->{reserved_at}, 0)->as_string,
                price    => $event->{sheets}->{price}->{$sheet->{rank}},
            };
            push @reports => $report;
        }
    }

    return $self->render_report_csv($c, \@reports);
};

sub render_report_csv {
    my ($self, $c, $reports) = @_;
    my @reports = sort { $a->{sold_at} <=> $b->{sold_at} } @$reports;

    my $body = "event_id,sold_at,price\n";
    for my $report (@reports) {
        $body .= qq!$report->{event_id},"$report->{sold_at}",$report->{price}\n!;
    }

    my $res = $c->req->new_response(200, [
        'Content-Type'        => 'text/csv; charset=UTF-8',
        'Content-Disposition' => 'attachment; filename="report.csv"',
    ], $body);
    return $res;
}

1;
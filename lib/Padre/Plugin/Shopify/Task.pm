#!/usr/bin/perl
use strict;
use warnings;

use WWW::Shopify::Tools::Themer;

package Padre::Plugin::Shopify::Themer;
use parent 'WWW::Shopify::Tools::Themer';

sub new {
	my ($package, $task, $settings) = @_;
	my $self = $package->SUPER::new($settings);
	$self->{task} = $task;
	return $self;
}

sub log {
	my ($self, $message) = @_;
	chomp($message);
	$self->{task}->tell_status($message);
}

sub task { return shift->{task}; }

package Padre::Plugin::Shopify::Task;
use parent 'Padre::Task';

sub new {
	my $package = shift;
	my $self = $package->SUPER::new(@_);
	my %settings = @_;
	my ($action, $project) = ($settings{action}, $settings{project});
	$self->{action} = $action;
	$self->{directory} = $project->directory;
	$self->{email} = $project->email;
	$self->{password} = $project->password;
	$self->{url} = $project->url;
	$self->{api_key} = $project->api_key;
	$self->{manifest} = $project->manifest;
	return $self;
}

sub run {
	my ($self) = @_;
	my $action = $self->{action};
	my $themer = Padre::Plugin::Shopify::Themer->new($self, $self->{email} ?
		{ email => $self->{email}, password => $self->{password}, url => $self->{url} } :
		{ apikey => $self->{api_key}, password => $self->{password}, url => $self->{url} }
	);
	if ($self->{manifest}) {
		$themer->manifest($self->{manifest});
	}
	else {
		$themer->manifest->load($self->{directory} . "/.shopmanifest");
	}
	eval {
		$themer->$action($self->{directory});
	};
	if (my $exception = $@) {
		my $string = $themer->read_exception($exception);
		$themer->log("Error: $string");
	}
	$themer->manifest->save($self->{directory} . "/.shopmanifest");
	return 1;
}

1;
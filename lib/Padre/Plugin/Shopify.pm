#!/usr/bin/perl

use strict;
use warnings;

package Padre::Plugin::Shopify::Exception;
sub new { return bless { error => $_[1] }, $_[0]; }
sub error { return $_[0]->{error}; }

package Padre::Plugin::Shopify::Panel;
use base 'Wx::Panel';

sub project { return shift->{project}; }
sub new {
	my ($package, $project, $parent) = @_;
	my $self = $package->SUPER::new($parent);
	$self->{project} = $project;
	return $self;
}

sub view_panel { return 'bottom'; }
sub view_label { return Wx::gettext(shift->project->name); }
sub view_close { shift->project->remove; }

package Padre::Plugin::Shopify::Themer;
use base 'WWW::Shopify::Tools::Themer';

sub project { return shift->{project} }

sub new {
	my ($package, $project, $settings) = @_;
	my $self = $package->SUPER::new($settings);
	$self->{project} = $project;
	my $directory = $project->directory;
	$self->manifest->load("$directory/.shopmanifest") if -e "$directory/.shopmanifest";
	return $self;
}

sub log {
	my ($self, $message) = @_;
	chomp($message);
	$message =~ s/^\[.*?\]\s*//;
	$self->project->plugin->main->status($message);
}

sub transfer_progress {
	my ($self, $type, $theme, $files_transferred, $files_total, $file) = @_;
	$self->project->progress($files_transferred / $files_total);
	return $self->SUPER::transfer_progress($type, $theme, $files_transferred, $files_total, $file);
}

package Padre::Plugin::Shopify::Project;
use WWW::Shopify::Tools::Themer;
use JSON qw(decode_json encode_json);
use File::Slurp;

sub new {
	my ($package, $plugin, $directory, $settings) = @_;
	my $self = bless { %$settings, directory => $directory, plugin => $plugin, sa => undef, panel => undef, autopush => 0 }, $package;
	my $height = 30;
	$self->{panel} = Padre::Plugin::Shopify::Panel->new( $self, $self->plugin->main->bottom, -1, [-1, -1], [-1, $height] );
	my $box = Wx::BoxSizer->new(Wx::wxHORIZONTAL);
	my $theme_selector = Wx::ComboBox->new( $self->panel, -1, "<< ALL >>", [-1, -1], [200, $height], ["<< ALL >>"]);
	my ($autopush_button, $pull_button, $push_button) = map { Wx::BitmapButton->new( $self->panel, -1, $self->plugin->{images}->{$_}, [-1, -1], [-1, $height], Wx::wxBU_EXACTFIT ) } ("refresh", "pull", "push");
	my $loading_bar = Wx::Gauge->new($self->panel, -1, 100, [-1, -1], [200, $height]);
	$box->Add($_) for ($theme_selector, $autopush_button, $pull_button, $push_button);
	$box->Add($loading_bar, 1);
	$self->{loading_bar} = $loading_bar;
	$self->{theme_selector} = $theme_selector;
	$self->{autopush_button} = $autopush_button;
	Wx::Event::EVT_BUTTON( $self->panel, $pull_button, sub { $self->pull; });
	Wx::Event::EVT_BUTTON( $self->panel, $push_button, sub { $self->push; });
	Wx::Event::EVT_BUTTON( $self->panel, $autopush_button, sub { $self->autopush($self->autopush ? 0 : 1); });
	$self->panel->SetSizerAndFit($box);
	$self->plugin->main->bottom->show( $self->panel );
	return $self;
}

sub plugin { return shift->{plugin}; }
sub panel { return shift->{panel}; }
sub directory { return shift->{directory}; }

sub progress {
	my ($self, $percent) = @_;
	$self->{loading_bar}->SetValue(int($percent * 100));
}

sub remove {
	my ($self) = @_;
	$self->plugin->remove_project($self);
}

sub name { my ($self) = @_; return $self->shop->name; }

sub shop {
	my ($self) = @_;
	my $directory = $self->directory;
	return $self->{shop} if $self->{shop};
	if (-e "$directory/.shopinfo") {
		$self->{shop} = WWW::Shopify::Model::Shop->from_json(decode_json(read_file("$directory/.shopinfo")));
	}
	else {
		$self->{shop} = $self->sa->get_shop;
		write_file("$directory/.shopinfo", encode_json($self->{shop}->to_json));
	}
	return $self->{shop};
}

sub themer {
	my ($self) = @_;
	return $self->{themer} if $self->{themer};
	$self->{themer} = new Padre::Plugin::Shopify::Themer($self, { email => $self->email, password => $self->password, url => $self->url }) if ($self->email);
	$self->{themer} = new Padre::Plugin::Shopify::Themer($self, { apikey => $self->api_key, password => $self->password, url => $self->url }) if (!$self->email);
	return $self->{themer};
}

sub sa {
	my ($self) = @_;
	return $self->themer->sa;
}

sub push { 
	my ($self) = @_;
	$self->progress(0);
	if ($self->{theme_selector}->GetValue eq "<< ALL >>") {
		$self->plugin->main->status("Pushing all themes...");
		$self->themer->push_all($self->directory);
		$self->plugin->main->status("Complete.");
	}
	my $directory = $self->directory;
	$self->themer->manifest->save("$directory/.shopmanifest");
	$self->progress(1);
}
sub pull {
	my ($self) = @_;
	$self->progress(0);
	if ($self->{theme_selector}->GetValue eq "<< ALL >>") {
		$self->plugin->main->status("Pulling all themes...");
		$self->themer->pull_all($self->directory);
		$self->plugin->main->status("Complete.");
	}
	my $directory = $self->directory;
	$self->themer->manifest->save("$directory/.shopmanifest");
	$self->progress(1);
}

sub url { $_[0]->{url} = $_[1] if defined $_[1]; return $_[0]->{url}; }
sub api_key { $_[0]->{api_key} = $_[1] if defined $_[1]; return $_[0]->{api_key}; }
sub password { $_[0]->{password} = $_[1] if defined $_[1]; return $_[0]->{password}; }
sub email { $_[0]->{email} = $_[1] if defined $_[1]; return $_[0]->{email}; }


sub autopush { 
	my ($self) = @_;
	if (defined $_[1]) {
		$self->{autopush} = $_[1];
		my $bitmap = $self->plugin->{images}->{$self->{autopush} ? "refresh-off" : "refresh"};
		$self->{autopush_button}->SetBitmapSelected($bitmap);
		$self->{autopush_button}->SetBitmapFocus($bitmap);
		$self->{autopush_button}->SetBitmapDisabled($bitmap);
		$self->{autopush_button}->SetBitmapHover($bitmap);
		$self->{autopush_button}->SetBitmapLabel($bitmap);
	}
	return $_[0]->{autopush};
}

package Padre::Plugin::Shopify;
use base 'Padre::Plugin';
use File::ShareDir qw(dist_dir);
use File::Slurp;
use JSON qw(decode_json encode_json);

our $VERSION = '0.01';

sub new {
	my ($package, @args) = @_;
	my $self = $package->SUPER::new(@args);
	$self->{projects} = [];
	$self->{autopush} = 0;

	$self->{images} = {};
	my $dist_dir = dist_dir("WWW-Shopify-Tools-Themer");
	for ("pull", "push", "refresh", "refresh-off") {
		my $image = Wx::Image->new();
		$image->LoadFile("$dist_dir/$_.png", Wx::wxBITMAP_TYPE_PNG);
		my $bitmap = Wx::Bitmap->new($image);
		if ($bitmap->Ok) {
			$self->{images}->{$_} = $bitmap;
		}
		else {
			print STDERR "Unable to load $_\n";
		}
	}
	return $self;
}

sub plugin_name { "Shopify Plug-In"; }

sub padre_interfaces {
	return (
		'Padre::Plugin' 	=> '0.91',
		'Padre::Wx::Role::Main' => '0.91',
		'Padre::Wx'             => '0.91',
	);
}

use List::Util qw(first);
sub padre_hooks { return {'after_save' => sub {
	my ($self, $document) = @_;
	# Task this so we don't freeze. $self->ide->
	my $project = first { index($document->filename, $_->directory) != -1 } $self->projects;
	# If this is on a project we're working on, push that theme specifically.
	if ($project && $project->autopush) {
		my $theme = first { index($document->filename, $_->{id}) != -1 } @{$project->themer->manifest->{themes}};
		$project->themer->push(new WWW::Shopify::Model::Theme($theme), $project->directory);
	}
}}; }

use constant CHILDREN => 'Padre::Plugin::Shopify';

sub pull_all { my ($self) = @_; $_->pull for ($self->projects); }
sub push_all { my ($self) = @_; $_->push for ($self->projects); }

sub menu_plugins_simple {
	my $self = shift;
	return $self->plugin_name => [
		'Create Shop' => sub { $self->create_shop_dialog },
		'Open Shop' => sub { $self->open_shop_dialog },
		'Pull Open Shops' => sub { $self->pull_all },
		'Push Open Shops' => sub { $self->push_all },
		'About' => sub { $self->show_about },
	];
}

sub projects { return @{$_[0]->{projects}}; }
sub add_project {
	my ($self, $project) = @_;
	push(@{$self->{projects}}, $project);
	return $project;
}

sub remove_project {
	my ($self, $project) = @_;
	$self->{projects} = [grep { $_ != $project } @{$self->{projects}}];
}

sub show_about {
	my $self = shift;
	# Generate the About dialog
	my $about = Wx::AboutDialogInfo->new;
	$about->SetName('Shopify Plug In');
	$about->SetDescription('A plugin for the Shopify theme tool.');
	# Show the About dialog
	Wx::AboutBox($about);

	return;
}

sub open_shop_dialog {
	my ($self) = @_;
	my $main = $self->main;
	my $dialog = Wx::DirDialog->new($main, -1);
	if ($dialog->ShowModal == Wx::wxID_OK) {
		$self->open_shop($dialog->GetPath);
	}
}

sub create_shop_dialog {
	my ($self) = @_;
	my $main = $self->main;
	my $dialog = Wx::DirDialog->new($main, -1);
	$self->create_shop($dialog->GetPath) if $dialog->ShowModal == Wx::wxID_OK;
}

sub open_shop {
	my ($self, $directory) = @_;
	eval {
		die new Padre::Plugin::Shopify::Exception("Unable to find directory.") unless -d $directory;
		my ($setting_file, $manifest_file) = ("$directory/.shopsettings", "$directory/.shopmanifest");
		die new Padre::Plugin::Shopify::Exception("Unable to find directory files.") unless -e $setting_file && -e $manifest_file;
		my $file_settings = decode_json(read_file($setting_file));
		$self->add_project(Padre::Plugin::Shopify::Project->new($self, $directory, $file_settings));
	};
	if ($@) {
		$self->main->info(ref($@) ? $@->error : $@);
	}
}

sub create_shop {
	my ($self, $directory) = @_;
	eval {
		die new Padre::Plugin::Shopify::Exception("Unable to find directory.") unless -d $directory;
		my ($setting_file, $manifest_file) = ("$directory/.shopsettings", "$directory/.shopmanifest");
		die new Padre::Plugin::Shopify::Exception("Found already extant settings files. Not creating.") if -e $setting_file || -e $manifest_file;
		my $dialog = Wx::Dialog->new($self->main, -1, "Create Shop");
		my $grid = Wx::FlexGridSizer->new( 4, 2, 1, 1);
		
		my ($url_edit, $api_key_edit, $password_edit) = map { Wx::TextCtrl->new( $dialog, -1, '' ) } 0..2;
		my ($url_text, $password_text) = map { Wx::StaticText->new( $dialog, -1, $_ )} ("Shop URL", "Password");
		my $api_key_text = Wx::ComboBox->new($dialog, -1, "API Key", [-1, -1], [-1, -1], ["API Key", "Email"]);
		my ($okay_button, $cancel_button) = map { Wx::Button->new( $dialog, -1, $_ ) } ("OK", "Cancel");
		$grid->Add($_, 0, Wx::wxGROW|Wx::wxALL, 2 ) for($url_text, $url_edit, $api_key_text, $api_key_edit, $password_text, $password_edit, $cancel_button, $okay_button);
		$dialog->SetAutoLayout( 1 );
		$dialog->SetSizer($grid);
		$grid->Fit($dialog);
		$grid->SetSizeHints($dialog);
		Wx::Event::EVT_BUTTON( $dialog, $okay_button, sub { $dialog->EndModal(Wx::wxID_OK); });
		Wx::Event::EVT_BUTTON( $dialog, $cancel_button, sub { $dialog->EndModal(Wx::wxID_CANCEL); });
		if ($dialog->ShowModal == Wx::wxID_OK) {
			my $settings = { hostname => $url_edit->GetValue, password => $password_edit->GetValue };
			$settings->{api_key} = $api_key_text->GetValue eq "API Key";
			$settings->{email} = $api_key_text->GetValue eq "Email";
			$self->add_project(Padre::Plugin::Shopify::Project->new($self, $directory, $settings));
		}
	};
	if ($@) {
		$self->main->info(ref($@) ? $@->error : $@);
	}
}

sub plugin_enable {
	my $self = shift;
	my $return = $self->SUPER::plugin_enable(@_);
	
	my $config = $self->config_read;
	if ($config && $config->{projects}) {
		$self->open_shop($_) for (@{$config->{projects}});
	}
	return $return;
}

sub plugin_disable {
	my $self = shift;
	$self->config_write( { projects => [ map { $_->directory } $self->projects] } );
	for my $package (CHILDREN) {
		require Padre::Unload;
		Padre::Unload->unload($package);
	}
	$self->plugin->main->bottom->hide( $_->panel ) for ($self->projects);
	$self->SUPER::plugin_disable(@_);
	return 1;
}


1;

__END__

=pod

=head1 NAME

Padre::Plugin::Shopify - Interface to WWW::Shopify::Tools::Themer.

=head1 DESCRIPTION

A simple plugin for padre that lets you push and pull Shopify themes. Preliminary upload.

=head1 COPYRIGHT & LICENSE

Perl License, 2013.

=cut

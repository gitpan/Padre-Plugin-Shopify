#!/usr/bin/perl

use strict;
use warnings;
use Scalar::Util qw(weaken);

package Padre::Plugin::Shopify::Exception;
sub new { return bless { error => $_[1] }, $_[0]; }
sub error { return $_[0]->{error}; }

package Padre::Plugin::Shopify::Panel;
use base qw(Padre::Wx::Role::Main Padre::Wx::Role::View Wx::Panel);
use Scalar::Util qw(weaken);


sub project { return shift->{project}; }
sub new {
	my ($package, $project) = @_;	
	my $height = 30;
	my $self = $package->SUPER::new($project->plugin->main->bottom, -1, [-1,-1], [-1, $height]);
	$self->{project} = $project;
	#weaken($self->{project});
	my $box = Wx::BoxSizer->new(Wx::wxHORIZONTAL);
	my $theme_selector = Wx::ComboBox->new( $self, -1, "<< ALL >>", [-1, -1], [200, $height], ["<< ALL >>"]);
	my ($autopush_button, $pull_button, $push_button) = map { Wx::BitmapButton->new( $self, -1, $self->project->plugin->{images}->{$_}, [-1, -1], [-1, $height], Wx::wxBU_EXACTFIT ) } ("refresh", "pull", "push");
	my $loading_bar = Wx::Gauge->new($self, -1, 100, [-1, -1], [200, $height]);
	$box->Add($_) for ($theme_selector, $autopush_button, $pull_button, $push_button);
	$box->Add($loading_bar, 1);
	$self->{loading_bar} = $loading_bar;
	$self->{theme_selector} = $theme_selector;
	$self->{autopush_button} = $autopush_button;
	Wx::Event::EVT_BUTTON( $self, $pull_button, sub { $self->project->pull; });
	Wx::Event::EVT_BUTTON( $self, $push_button, sub { $self->project->push; });
	Wx::Event::EVT_BUTTON( $self, $autopush_button, sub { $self->project->autopush($self->project->autopush ? 0 : 1); });
	$self->SetSizerAndFit($box);
	$self->project->plugin->main->show_output(1);
	$self->project->plugin->main->bottom->show( $self );
	$self->project->plugin->main->refresh;
	#$self->project->plugin->main->bottom->SetMaxSize([-1, $height]);
	return $self;
}

sub progress {
	my ($self, $percent) = @_;
	$self->{loading_bar}->SetValue(int($percent * 100));
}

sub view_panel { return 'bottom'; }
sub view_label { return Wx::gettext(shift->project->name); }
sub view_close { shift->project->remove; }

package Padre::Plugin::Shopify::Project;
use parent 'Padre::Role::Task';
use JSON qw(decode_json encode_json);
use File::Slurp;
use WWW::Shopify;
use WWW::Shopify::Model::Shop;
use Padre::Plugin::Shopify::Task;
use Scalar::Util qw(weaken);

use Data::Dumper;

sub manifest { $_[0]->{manifest} = $_[1] if defined $_[1]; return $_[0]->{manifest}; }

sub update_combobox {
	my ($self) = @_;
	$self->panel->{theme_selector}->Clear;
	$self->panel->{theme_selector}->Append("<< ALL >>");
	my @themes = @{$self->manifest->{themes}};
	$self->panel->{theme_selector}->Append($_->{name}) for (@themes);
}

sub task_status {
	my ($self, $message) = @_;
	if ($message =~ m/^\[\s*(.*?)\s*\%\s*\]\s*(.*?)\s*$/) {
		my $percent = $1/100;
		$self->progress($percent);
		$self->plugin->main->status($message);
	}
	elsif ($message =~ m/Error: /) {
		$self->plugin->main->info($message);
	}
}

sub task_finish {
	my ($self, $task) = @_;
	$self->plugin->main->status("Complete.");
	$self->manifest($task->{manifest});
	$self->progress(1);
}

sub task_run {
	my ($self, $task) = @_;
	$self->manifest($task->{manifest});
	$self->progress(0);
}

sub new {
	my ($package, $plugin, $directory, $settings) = @_;
	my $self = bless { %$settings, directory => $directory, plugin => $plugin, sa => undef, panel => undef, autopush => 0 }, $package;
	my $height = 30;
	#weaken($self->{plugin});
	$self->{panel} = Padre::Plugin::Shopify::Panel->new( $self );
	$self->manifest(decode_json(read_file($directory . "/.shopmanifest")));
	$self->update_combobox;
	return $self;
}

sub plugin { return shift->{plugin}; }
sub panel { return shift->{panel}; }
sub directory { return shift->{directory}; }

sub progress {
	my ($self, $percent) = @_;
	$self->panel->progress($percent);
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
		$self->{shop} = WWW::Shopify->new($self->url, $self->email, $self->password)->get_shop;
		write_file("$directory/.shopinfo", encode_json($self->{shop}->to_json));
	}
	return $self->{shop};
}

use List::Util qw(first);

sub push { 
	my ($self) = @_;
	$self->progress(0);
	my $name = $self->panel->{theme_selector}->GetValue;
	if ($name eq "<< ALL >>") {
		$self->plugin->main->status("Pushing all themes...");
		$self->task_request(
			task        => 'Padre::Plugin::Shopify::Task',
			on_finish   => 'task_finish',
			on_status   => 'task_status',
			on_run 	    => 'task_run',
			action	    => "push_all",
			project	    => $self
		);
	}
	else {
		$self->plugin->main->status("Pushing theme $name...");
		my $theme = first { $_->{name} eq $name } @{$self->manifest->{themes}};
		if ($theme) {
		        my $id = $theme->{id};
			$self->task_request(
				task        => 'Padre::Plugin::Shopify::Task',
				on_finish   => 'task_finish',
				on_status   => 'task_status',
				on_run 	    => 'task_run',
				action	    => "push:$id",
				project	    => $self
			);
		}
		else {
			$self->plugin->main->info("Can't find theme $name.");
		}
	}
}
sub pull {
	my ($self) = @_;
	$self->progress(0);
	my $name = $self->panel->{theme_selector}->GetValue;
	if ($name eq "<< ALL >>") {
		$self->plugin->main->status("Pulling all themes...");
		$self->task_request(
			task        => 'Padre::Plugin::Shopify::Task',
			on_finish   => 'task_finish',
			on_status   => 'task_status',
			on_run 	    => 'task_run',
			action	    => "pull_all",
			project	    => $self
		);
	}
	else {
		$self->plugin->main->status("Pulling theme $name...");
		my $theme = first { $_->{name} eq $name } @{$self->manifest->{themes}};
		if ($theme) {
		        my $id = $theme->{id};
			$self->task_request(
				task        => 'Padre::Plugin::Shopify::Task',
				on_finish   => 'task_finish',
				on_status   => 'task_status',
				on_run 	    => 'task_run',
				action	    => "pull:$id",
				project	    => $self
			);
		}
		else {
			$self->plugin->main->info("Can't find theme $name.");
		}
	}
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
		$self->panel->{autopush_button}->SetBitmapSelected($bitmap);
		$self->panel->{autopush_button}->SetBitmapFocus($bitmap);
		$self->panel->{autopush_button}->SetBitmapDisabled($bitmap);
		$self->panel->{autopush_button}->SetBitmapHover($bitmap);
		$self->panel->{autopush_button}->SetBitmapLabel($bitmap);
	}
	return $_[0]->{autopush};
}

package Padre::Plugin::Shopify;
use base 'Padre::Plugin';
use File::ShareDir qw(dist_dir);
use File::Slurp;
use JSON qw(decode_json encode_json);

our $VERSION = '0.03';

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
	my $project = first { index($document->filename, $_->directory) != -1 } $self->projects;
	# If this is on a project we're working on, push that theme specifically.
	$project->push if ($project && $project->autopush);
}}; }

use constant CHILDREN => 'Padre::Plugin::Shopify', 'Padre::Plugin::Shopify::Task';

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

use List::Util qw(first);
use Cwd 'abs_path';
sub open_shop {
	my ($self, $directory) = @_;
	eval {
		die new Padre::Plugin::Shopify::Exception("Unable to find directory.") unless -d $directory;
		my ($setting_file, $manifest_file) = ("$directory/.shopsettings", "$directory/.shopmanifest");
		die new Padre::Plugin::Shopify::Exception("Unable to find directory files.") unless -e $setting_file && -e $manifest_file;
		my $file_settings = decode_json(read_file($setting_file));
		return if first { abs_path($_->directory) eq $directory } $self->projects;
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

use Padre::Locale::T;
sub plugin_enable {
	my $self = shift;
	my $return = $self->SUPER::plugin_enable(@_);

	if (!Padre::MIME->find("application/liquid")->type) {
		Padre::MIME->create(
			type      => 'application/liquid',
			name      => 'Liquid',
			supertype => 'text/html',
			document  => 'Padre::Document::Liquid',
			extensions => 'liquid'
		);
		Padre::Wx::Action->new(
			name        => "view.mime.application/liquid",
			label       => "Liquid",
			comment     => _T('Switch document type'),
			menu_method => 'AppendRadioItem',
			menu_event  => sub {
				$_[0]->set_mimetype("application/liquid");
			},
		);
		$self->main->refresh;
	}
	
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

sub registered_highlighters {

}

sub provided_highlighters {
	return (['Padre::Document::Liquid', "Liquid", "Liquid syntax highglithing for padre."]);
}

sub highlighting_mime_types {
	return ('Padre::Document::Liquid' => ['application/liquid']);
}

sub registered_documents {
	return 'application/liquid' => 'Padre::Document::Liquid';
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

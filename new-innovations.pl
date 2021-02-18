#! ./perl

# ------------------------------------------------------------------------------
# Name: New Innovations Procedure Logger
# Desc: Capture all non-ultrasound prodedures performed by residents / fellows
# 		during the previous day relative to the date that this script is
# 		executed. The script contains a translation table for procedures that
# 		are worded differently in Allscripts and New Innovations such that
# 		it converts from the Allscripts name to the New Innovations name. A
# 		file is then created with all of the procedure details contained and
# 		uploads it to New Innovations via SFTP.
#
# Version: 1.0
# ------------------------------------------------------------------------------

use DBI;
use DBD::ODBC;
use Data::Dumper;
use File::Temp;
use Net::SFTP::Foreign;
use POSIX;
use MIME::Lite;
use DateTime;
use DateTime::Format::MSSQL;
use DateTime::Format::Strptime;
use Encode;
use Net::LDAP;
use Authen::SASL qw(Perl);
use Email::Address;

use warnings;
use strict;

# ------------------------------------------------------------------------------
# CONFIGURATION
# ------------------------------------------------------------------------------
my $system_path = "C:\\EM-Applications\\NewInnovations";
my $procedure_file = "procedures.txt";
my $error_log = "error.log";
my $info_log = "info.log";

my $sftp_host = "www.new-innov.com";
my $sftp_username = "";
my $sftp_key = "$system_path\\keys\\private.ppk";

my $database = '';
my $db_user  = '';
my $db_pass  = '';

my $admin_email = '';

# Email Form Settings
my %form;
$form{'from'} = '';
$form{'reply-to'} = '';

# Translation table for procedure names
# Allscripts procedures on the LEFT and New Innovations procedures on the RIGHT
my %translate_procedure_names = (
	'Central line - IJ'			=> 'CVC Internal Jugular Line',
	'Central line - Femoral'	=> 'CVC Femoral Line',
	'Central line - Subclavian'	=> 'CVC Subclavian Line',
	'Central line - Ultrasound - IJ'			=> 'CVC Internal Jugular Line Ultrasound Guided',
	'Central line - Ultrasound - Femoral'		=> 'CVC Femoral Line Ultrasound Guided',
	'Central line - Ultrasound - Subclavian'	=> 'CVC Subclavian Line Ultrasound Guided',
	'Chest tube placement'		=> 'Chest Tube',
	'Cardioversion'				=> 'Cardioversion/Defibrillation',
	'Endotracheal Intubation'	=> 'Intubation',
	'Emergency delivery'		=> 'Vaginal Delivery',
	'Foreign body'				=> 'Foreign Body Removal',
	'Intraosseous infusion'		=> 'Intraosseous IV Line',
	'IV access'					=> 'Peripheral IV',
	'Joint Reduction'			=> 'Dislocation Reduction',
	'Lumbar puncture'			=> 'Lumbar Puncture',
	'Nail bed laceration'		=> 'Laceration Repair',
	'Paracentesis'				=> 'Paracentesis or Periotoneal Lavage',
	'Peritoneal lavage'			=> 'Paracentesis or Periotoneal Lavage',
	'Pelvic exam'				=> 'Pelvic',
	'Slit lamp examination'		=> 'Slit Lamp Exam',
	'Splint/cast placement'		=> 'Closed Fracture Splinting',
);

# -----------------------------------------------------------------------------
# MAIN
# -----------------------------------------------------------------------------

my $results = GetProcedures();
WriteProcedureFile($results);
WriteDatabase($results);
SecureTransfer();
ComposeResidentEmail($results);

# -----------------------------------------------------------------------------
# SUBROUTINES
# -----------------------------------------------------------------------------

# Connect to the New Innovations secure server
sub SecureTransfer {
	my $sftp = Net::SFTP::Foreign->new(
		host => $sftp_host, 
		user => $sftp_username,
		port => 22,
		key_path => $sftp_key,
		ssh_cmd => 'plink' 
	);
	$sftp->error and die "unable to connect to remote host: " . $sftp->error;
	
	WriteLog("Connecting to $sftp_host using SFTP.");
	WriteLog("Putting file $system_path\\$procedure_file on remote server.");
	$sftp->put("$system_path\\$procedure_file", "$procedure_file");

	# Alert the admin to success and failure
	if ($sftp->error) {
		WriteLog("There was an error SFTPing the file to NI. See the error log for more information.");
		WriteError($sftp->error);
		AlertAdmin('0', "$sftp->error");
	} else {
		WriteLog("File successfully placed on remote server.");
		AlertAdmin('1', "");
	}
}

# Write any problems with connecting to the SSH server or writing the procedure file
# to the error log
sub WriteError {
	my ($line) = $_[0];
	my $timestamp = GetTimestamp();

	if ($error_log) {
		if (-w $system_path) {
			open (ERRORLOG, ">> $system_path\\$error_log");
    		print ERRORLOG "$timestamp -- " . $line . "\n";
 			close (ERRORLOG); 
		} else {
			print "ERROR: Cannot write to directory $system_path. Check path.\n";
		}
	}
}

# Write all procedure to the info log
sub WriteLog {
	my ($line) = $_[0];
	my $timestamp = GetTimestamp();

	if ($info_log) {
		if (-w $system_path) {
			open (INFOLOG, ">> $system_path\\$info_log");
    		print INFOLOG "$timestamp -- " . $line . "\n";
 			close (INFOLOG); 
		} else {
			print "ERROR: Cannot write to directory $system_path. Check path.\n";
		}
	}
}

# Retrieve the residents' procedures
sub GetProcedures {
	my $dbh = ExportDB();

	# 1,0 signifies that we want all of the procedures >= yesterday 00:00:00 and 
	# < today 00:00:00 (24 hour period)
	my $sth = $dbh->prepare("GetResidentsProcedures 1,0");

	# Execute the SQL procedure
	$sth->execute();
	WriteLog("GetResidentsProcedures prepared and executed");
	
	my $array_ref = $sth->fetchall_arrayref(); # Fetch all fields of every row

	# Disconnect from DB
	$sth->finish;
	$dbh->disconnect;

	return ($array_ref);
}

# Write the procedures to the procedure file
sub WriteProcedureFile {
	my ($results) = $_[0];
	my ($header, $line, $exists);

	# No need to remove the file after we are done because we will keep 
	# overwriting it every time!
	if (-w $system_path) {
		open (PROCFILE, "> $system_path\\$procedure_file");
		
		WriteLog("Opening $system_path\\$procedure_file");
		WriteLog("Writing procedures to file");

		# FILE FORMAT EXPLANATION
		# ---------------------------------------------------------------------------
		# PL|EMAILSUPERVISOR : set to 1 to enable emailing the attending physician
		# PL|Confirmed : set to 0 to disable automatic confirmation of procedure
		# PL|Pass : set to 0 to disable passing procedure directly
		$header = "PL|residentid|uniqueid|allscripts\tPL|supervisorid|uniqueid|allscripts\tPL|ProcedureName\tPL|DatePerformed\tPL|PatientID\tPL|PatientDOB\tPL|PatientGender\tPL|ResidentComment\tPL|EMAILSUPERVISOR\tPL|Confirmed\tPL|Pass";
		print PROCFILE "$header\n";

		foreach my $row (@{ $results }) {
			my ($mrn, $encounter_no, $dob, $gender, $procedure_date, $procedure_id, $procedure_name, 
				$procedure_comment, $resident_id, $attending_id, $resident_name, $attending_name) = @$row;
			
			($exists, $procedure_name) = LookupProcedure($procedure_name);
			$procedure_date = FormatDate($procedure_date, '%m/%d/%Y');
			$dob = FormatDate($dob, '%m/%d/%Y');

			$line = "$resident_id\t$attending_id\t$procedure_name\t$procedure_date\t$mrn\t$dob\t$gender\t$procedure_comment\t1\t0\t0";
			
			print PROCFILE "$line\n";			
			WriteLog($line);
		}

 		close (PROCFILE);
 		WriteLog("Closing file");
	} else {
		WriteError("Cannot open path to $system_path\\$procedure_file");
	}
}

# Write to the database for every procedure we log into the procedure file
sub WriteDatabase {
	my ($results) = $_[0];
	my $dbh = ExportDB ();
	my $timestamp = GetTimestamp ();
	my ($exists);

	my $sth = $dbh->prepare("INSERT INTO NewInnovations (MRN, EncounterNo, 
		InsertionTime, ResidentID, AttendingID, ProcedureName, ProcedureDate, 
		ProcedureComment, Found) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)");

	WriteLog("Writing procedures to database");
	
	# Execute the SQL procedure
	foreach my $row (@{ $results }) {
		my ($mrn, $encounter_no, $dob, $gender, $procedure_date, $procedure_id, $procedure_name, 
			$procedure_comment, $resident_id, $attending_id, $resident_name, $attending_name) = @$row;
	
		($exists, $procedure_name) = LookupProcedure($procedure_name);

		$sth->execute($mrn, $encounter_no, $timestamp, $resident_id, $attending_id,
				$procedure_name, $procedure_date, $procedure_comment, $exists);
		WriteLog("@$row");
	}	

	WriteLog("Finished writing procedures to database");
	
	# Disconnect from DB
	$sth->finish;
	$dbh->disconnect;
}

# Alert the administrator to the success or failure of the script
sub AlertAdmin {
	my ($code) = $_[0];
	my ($content) = $_[1];
	
	if ($code eq '1') {
		SendEmail($admin_email, '[SUCCESS] New Innovations Procedure Logger', $content);
	} else {
		SendEmail($admin_email, '[FAIL] New Innovations Procedure Logger', $content);
	}
}

# Let the residents know which of their procedures where found by this script
# and uploaded to NewInnovations
sub ComposeResidentEmail {
	my ($results) = $_[0];
	my (%residents, $content, $procedure_status);

	# Identify all of the residents
	foreach my $row (@{ $results }) {
		$residents{@$row[8]}++;
	}

	foreach my $resident (sort keys %residents) {
		$content = "
		<html>
		<head>
			<style type=\"text/css\">
			html{
				font-family: Arial, Verdana, sans-serif;
				}
			p, h4, li, ul {
				font-size: 0.8em;
			}
			table{
			    border: 0;
			    border-collapse: collapse;
			    table-layout: fixed;
				width: 600px;
			}
			th {
				font-size: 0.8em;
				text-align: left;
				font-weight: bold;
			    margin: 0;
				padding: 0;
			}
			td {
				font-size: 0.8em;
				text-align: left;
			}
			</style>
		</head>
		<body>
			<table> 
			<tr>
				<th colspan='2'>Procedure Name</th>
				<th colspan='1'>Procedure Date</th>
				<th colspan='1'>Patient MR#</th>
				<th colspan='1'>Attending Name</th>
			</tr>
		";
		foreach my $row (@{ $results }) {
			if ($resident eq @$row[8]) {

				$content .= "
				<tr>
					<td colspan='2'>@$row[6]</td>
					<td colspan='1'>" . FormatDate(@$row[4], '%m/%d/%Y') . "</td>
					<td colspan='1'>@$row[0]</td>
					<td colspan='1'>@$row[11]</td>
				</tr>
				";
			}
		}
		$content .= "
			</table>
			<div id=\"footer\" style=\"margin-top: 2.0em; border-top: 1px solid #dedede; padding-bottom: 0.25em; border-bottom: 1px solid #dedede;\">
			<p><b>Attention:</b> Only the procedures which are in New Innovations will be automatically logged.</p>
			<p>The following are procedures are <u><b>NOT</b></u> automatically logged:</p>
			<ul>
				<li><b>ALL</b> Ultrasound Imaging!</li>
				<li>Laryngeal Mask Airway</li>
				<li>Needle Decompression of the Chest</li>
				<li>Open Thoracotomy / Thoracostomy</li>
			</ul>
			</div>
			<div style=\"margin-top: 1.0em;\">
				<p>Questions or Concerns? Contact <a href=\"mailto:\">Emil Soleyman</a></p>
			</div>
		</body>
		</html>
		";

		my $email = LookupEmail($resident);
		my $date  = GetDate('-1');
		SendEmail($email, "[$date] Allscripts Procedures", $content);
		
		# Clean up the email's body content by undefining the variable and so that we can
		# send another email
		undef $content;
	}
}

# Given a set of parameters, send the email to each resident
sub SendEmail {
	my ($to_address, $subject, $content) = @_;
	my ($msg);

	# Prepare email template
    MIME::Lite->send(
    	'smtp', # protocol
    	'',		# server
    	Timeout=>60
    );
    	
    $msg = MIME::Lite->new (
		From 		=> $form{'from'},
        'Reply-to'	=> $form{'reply-to'},
        To     		=> $to_address,
        Subject		=> "$subject",
    	Disposition => 'inline',
        Type  		=> 'multipart/alternative',
    );

	$msg->attr("content-type.charset" => "UTF-8");

    # convert to utf8, not a requirement for everyone....
    $content = encode("utf8", $content);

    # Add the html itself:
    $msg->attach(
		Type		=> 'text/html',
        Data		=> $content,
    );

	$msg->scrub(['content-disposition', 'content-length']);
	$msg->send;
}

# A single function to return the timestamp instead of doing the same
# thing multiple amount of times.
sub GetTimestamp {
	my $timestamp = POSIX::strftime('%Y-%m-%d %H:%M:%S', localtime);
	return ($timestamp);
}

# Format the MSSQL DateTime
sub FormatDate {
	my $mssql_date = $_[0];
	my $format = $_[1];

	my $dt_format = DateTime::Format::Strptime->new(
		pattern => "$format");

	my $date = DateTime::Format::MSSQL->parse_datetime($mssql_date);
	$date = $dt_format->format_datetime($date);

	return ($date);
}

# Retrieve the date given a +/- number of days from today
sub GetDate {
	my ($deviation) = $_[0];
	my ($action, $day_number);

	if ($deviation =~ m/^\+/) {
		$action = 'add';
	} else {
		$action = 'subtract';
	}

	if ($deviation =~ m/(\d+)/) {
		$day_number = $1;
	}

	my $today = DateTime->now;
	$today->set_time_zone('America/New_York');
    my $date = $today->clone->$action(days => $day_number); 
	my $date_string = sprintf("%s/%s/%s", $date->month, $date->day, $date->year);

	return ($date_string);
}

# Lookup the Allscripts procedure name and substitute the New Innovations name in
# its place otherwise return the Allscripts procedure name unadulterated
sub LookupProcedure {
	my $allscripts_procedure_name = $_[0];

	if (exists $translate_procedure_names{$allscripts_procedure_name}) {
		return ('1', $translate_procedure_names{$allscripts_procedure_name});
	} else {
		return ('0', $allscripts_procedure_name);
	}
}

# Email address lookup using Active Directory
sub LookupEmail {
	my $life_number = $_[0];
	my $email_address;

	# Create a Net::LDAP object for the MMC Active Directory
	my $ldap = Net::LDAP->new( 'ldap://', inet4 => 'Y', inet6 => 'fN' ) or die "Active Directory: $@";
	# Simple bind with DNS and password
	my $mesg = $ldap->bind( '', password => '' );

	if ($mesg->code) {
		#
		# if we've got an error... record it
		#
		LDAPerror ( "Searching", $mesg );
	}
	
	# If problems with binding, then throw an error
	$mesg->code && die $mesg->error;

	# Search using the DN (base) while filtering based on sn (last name) and
	# givenName (first name) and retrieving only the mail attribute
	$mesg = $ldap->search(
    	base   => "",
        filter => "",
		attrs	=> ['mail']
    );

	# If problems with search, then throw an error
	$mesg->code && die $mesg->error;

	# Get the email address for the sn and givenName
	foreach my $entry ($mesg->entries) { 
		$email_address = ${$entry->get('mail')}[0];
	}

	# Close our connection to Active Directory
	$mesg = $ldap->unbind;

	### ADDED: 2/6/2013
	# Only allow @domain.tld email addresses
	my $address = Email::Address->new(undef, $email_address);
	my $host = $address->host;

	# If the email address host DOES NOT EQUAL @domain.tld then make it
	# an empty variable
	if ($host ne 'domain.tld') {
		$email_address = '';
	}
	
	# Return the email address
	return ($email_address);
}

sub LDAPerror {
   my ($from, $mesg) = @_;
   print "Return code: ", $mesg->code;
   print "\tMessage: ", $mesg->error_name;
   print " :",          $mesg->error_text;
   print "MessageID: ", $mesg->mesg_id;
   print "\tDN: ", $mesg->dn;

   #---
   # Programmer note:
   #
   #  "$mesg->error" DOESN'T work!!!
   #
   #print "\tMessage: ", $mesg->error;
   #-----
}

# Export the database handle
sub ExportDB {
	my $dbh = DBI->connect("dbi:ODBC:$database", $db_user, $db_pass, 
		{ AutoCommit => 1,
		  ShowErrorStatement => 1,
		  HandleError        => \&DBIError,  		  
	});
	$dbh->{LongReadLen} = 30000; # Larger column size required!
	WriteLog("Connecting to $database database");

	return ($dbh);
}

# Handle the errors that DBI throws
sub DBIError {
	my ($message, $handle, $first_value) = @_;  

	SendEmail($admin_email, "[DB ERROR] New Innovation Procedure Logger", $message);

	return 1;  
}

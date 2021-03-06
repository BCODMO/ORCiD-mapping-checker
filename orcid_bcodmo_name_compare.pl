{
# orcid_bcodmo_name_compare.  WJS  Feb 17
#   Compares bcodmo and orcid given and family names.  See A Shepherd for details about
#   bcodmo, orcid, name fields, etc

# Input:
#   1) BCODMO users to look up
#     Input via http from URL hard-coded into this program.
#     Format of each input record is comma-separated list of quotation-mark-delimited strings.
#     First record lists names of fields in order they appear in rest of file.  Fields must include
#       orcid_url, person_uri, person_full_name, person_family_name, and person_given_name.  Fields may
#       occur in any order.  Other fields may be in input but will be ignored
#   2) ORCID information
#     Input via http from orcid_url fields of input from item 1 above
#     Format of input is XML.  Required XML fields are  family-name  and  given-names , nested inside 
#       personal-details , nested inside  orcid-bio , nested inside  orcid-profile .

# Mismatch information goes to stdout; summary information (and errors, if any) go to stderr
# Match if: non-empty family name AND
#           family names match AND
#           subset of given names match
#             Subset can be: whole given names match OR first N characters of given names match 
#                            OR shorter given name begins other given name

# Exit statuses:
#     0 all names matched
#     1 at least one name did NOT match
#     perl "&quit" status on some errors.  Program continues on others; notably failure to
#       retrieve orcid record corresponding to bcodmo name

# Switches (preceded by -s):
#   case_sensitive=[TRUE|FALSE]
#     Controls whether matches are to be case sensitive.  The default is FALSE
#     Synonyms for TRUE are YES and 1.  Synonyms for FALSE are NO and 0.  Case of keywords are ignored.
#     First letter of keyword is accepted.
#   strip_leading_and_trailing_blanks=[TRUE|FALSE]
#     Controls whether leading and trailing blanks are to be stripped from strings before comparison.  Default is FALSE
#     Keyword synonyms/rules same as for case_sensitive
#   given_name_match_length=N
#     Controls length of significant part of given name.  Default is 3
#     0 is a special value which means to use all of the shorter name
#     -1 is a special value which means to use all of each name
#
$version = "orcid_bcodmo_name_compare version 1.0a   2 Feb 2017";
#  2 Feb 17.  WJS
#     Comment change
#     [begin v 1.0a]

$TRUE = 1;
$FALSE = ! $TRUE;
$ILLEGAL = "NG";  # Must not match $TRUE or $FALSE

#   Next is arbitrary to match doc (and algorithm!) above.  Changed from original guess of 4 because of a
#   Ken/Kenneth reported mismatch
$default_given_name_match_length = 3;

$default_case_sensitive = $FALSE;
$default_strip_leading_and_trailing_blanks = $FALSE;

#   lod_url from A Shepherd email 26 Jan 17 
  $lod_url = "http://lod.bco-dmo.org/sparql?format=text%2Fcsv&timeout=0&query=SELECT+DISTINCT+%3Forcid_url+%3Fperson_uri+%3Fperson_full_name+%3Fperson_family_name+%3Fperson_given_name%0D%0AWHERE+%7B%0D%0A++%3Fperson_uri+rdf%3Atype+foaf%3APerson+.%0D%0A++%7B%3Fperson_uri+skos%3AexactMatch+%3Forcid_url+.%7D+%0D%0A++UNION%0D%0A++%7B%3Fperson_uri+odo%3Amatches+%3Forcid_url+.%7D%0D%0A++UNION+%7B%3Fperson_uri+owl%3AsameAs+%3Forcid_url+.%7D%0D%0A++FILTER+REGEX%28%3Forcid_url%2C+%22orcid.org%22%2C+%22i%22%29%0D%0A%0D%0A++%3Fperson_uri+rdfs%3Alabel+%3Fperson_full_name+.%0D%0A++%3Fperson_uri+foaf%3AfamilyName+%3Fperson_family_name+.%0D%0A++%3Fperson_uri+foaf%3AgivenName+%3Fperson_given_name+.%0D%0A%7D%0D%0AORDER+BY+%3Fperson_uri";

  @expected_lod_fields = ("orcid_url","person_uri","person_full_name","person_family_name","person_given_name");
#   Next line on inspection,  Note that fields may contain commas
  $lod_field_sep = q|","|;
  $q_lod_field_sep = quotemeta($lod_field_sep);

#   XML code taken from http://stackoverflow.com/questions/5725374/how-to-parse-a-simple-xml-file-to-a-readable-format
#   LWP code taken from http://www.xav.com/perl/site/lib/lwpcook.html
  use XML::Simple;
  use LWP::UserAgent;

  foreach (@ARGV) {
    ($switch,$switch_val) = split /\=/;
    (defined $switch_val) || &quit("*** Argument does not contain an = : $_");
    ($init,$switch) = ($switch =~ /(.)(.+)/);
    ((defined $init) && ($init eq "-")) || &quit( "*** Switch name does not begin with - : $_");
    ($switch eq "") && &quit( "*** No switch name after -");
    (defined $$switch) && &quit( "*** Multiple uses of switch $switch");
    if ($switch eq "case_sensitive") {
      $case_sensitive = &true_false($switch_val);
      ($case_sensitive eq $ILLEGAL) && &quit ("*** Illegal true/false value ==>$switch_val<== for case_sensitive switch");
    } elsif ($switch eq "strip_leading_and_trailing_blanks") {
      $strip_leading_and_trailing_blanks = &true_false($switch_val);
      ($strip_leading_and_trailing_blanks eq $ILLEGAL) && 
                &quit ("*** Illegal true/false value ==>$switch_val<== for strip_leading_and_trailing_blanks switch");
    } elsif ($switch eq "given_name_match_length") {
      &valid_number($switch_val) ||
                &quit ("*** ==>$switch_val<== not a numeric string (for given_name_match_length switch)");
      ($switch_val =~ /^[+-]?(\d+)$/) || 
                &quit ("*** ==>$switch_val<== not an integer (for given_name_match_length switch)");
      ($switch_val >= -1) ||
                &quit ("*** given_name_match_length switch must be >= -1: $switch_val");
      $given_name_match_length = $switch_val;
    } else {
      &quit ("*** Unknown switch/parameter $switch");
    }
  }
  foreach ("case_sensitive","strip_leading_and_trailing_blanks","given_name_match_length") {
    $default = "default_$_";
    (defined $default) || &quit( "*** Internal error - no definition for variable $default");
    (defined $$_) || ($$_ = $$default);
  }

  $lod_ua = LWP::UserAgent->new;
  $lod_req = HTTP::Request->new(GET => $lod_url);
  $lod_res = $lod_ua->request($lod_req);
  ($lod_res->is_success) || &quit( "*** Error retrieving //lod.bco-dmo.org/sparql URL: " . $lod_res->status_line);

  ($lod_fields,@lod_data) = split "\n", $lod_res->content;
#   Remove initial and trailing "s
  ($init,$lod_fields,$trail) = ($lod_fields =~ /^(.)(.*)(.)$/);
  (($init eq '"') && ($trail eq '"')) || &quit( "*** Did not find expected leading and trailing quotation marks in 1st lod record");
  @lod_fields = split /$q_lod_field_sep/,$lod_fields;
  $i = 0;
  foreach (@lod_fields) {
    $lod_index{$_} = $i;
    $i++;
  }
  $lod_field_count = $i;
  foreach (@expected_lod_fields) {
    (defined $lod_index{$_}) || &quit( "*** Did not find required field $_ in list of provided BCODMO fields");
  }


  $orcid_ua = LWP::UserAgent->new;
  $lod_count = $lod_processed_count = $mismatch_count = 0;
  foreach (@lod_data) {
    $lod_count++;

#     Remove initial and trailing "s
    ($init,$lod_rec,$trail) = /^(.)(.*)(.)$/;
    (($init eq '"') && ($trail eq '"')) || 
          &quit( "*** Did not find expected leading and trailing quotation marks in lod record ",$lod_count+1);
    @lod_fields = split /$q_lod_field_sep/,$lod_rec;
    (@lod_fields == $lod_field_count) || 
          &quit ("*** Did not get expected number of fields from lod record ",$lod_count+1,"\n",
               "*** \tExpected $lod_field_count; got ",scalar(@lod_fields));

    $lod_family_name = $lod_fields[$lod_index{"person_family_name"}];
    $lod_given_name = $lod_fields[$lod_index{"person_given_name"}];
    $lod_person_uri = $lod_fields[$lod_index{"person_uri"}];

    $orcid_url = $lod_fields[$lod_index{"orcid_url"}];
    $orcid_url || (  (print STDERR "*** empty ORCID URL field in lod record ",$lod_count+1,"\n")  &&  next);
    $lod_processed_count++;
    $orcid_req = HTTP::Request->new(GET => $orcid_url);
    $orcid_req->header('Accept' => 'application/xml');

    # send request
    $orcid_res = $orcid_ua->request($orcid_req);

    if ($orcid_res->is_success) {
      $orcid_data = XMLin($orcid_res->content);
  #     "Unwinding" of orcid XML done by inspection
      ($orcid_profile = ${$orcid_data}{"orcid-profile"}) || 
          &quit ("*** Could not find expected  orcid-profile  XML field in orcid record");
      ($orcid_bio = ${$orcid_profile}{"orcid-bio"}) || 
          &quit ("*** Could not find expected  orcid-bio  XML field in orcid record");
      ($orcid_personal_details = ${$orcid_bio}{"personal-details"}) || 
          &quit ("*** Could not find expected  personal-details  XML field in orcid record");
      ($orcid_given_names = ${$orcid_personal_details}{"given-names"}) || 
          &quit ("*** Could not find expected  given-names  XML field in orcid record");
      ($orcid_family_name = ${$orcid_personal_details}{"family-name"}) || 
          &quit ("*** Could not find expected  family-name  XML field in orcid record");
      $match_info = match_em();
      if ($match_info ne "MATCH") { 
        $mismatch_count++;
        if ($match_info =~ /amily/) { 
          $match_info .= " [BCODMO v ORCID] ==>$lod_family_name<== v ==>$orcid_family_name<==";
        } elsif ($match_info =~ /iven/) {
          $match_info .= " [BCODMO v ORCID] ==>$lod_given_name<== v ==>$orcid_given_names<==";
        }
        print "$lod_person_uri\n",
              "  Given Name: $lod_given_name\n",
              "  Family Name: $lod_family_name\n",
              "$orcid_url\n",
              "  Given Names: $orcid_given_names\n",
              "  Family Name: $orcid_family_name\n",
              "Issue: $match_info\n",
              "\n";
      }
    } else {
       &quit ("*** Error retrieving ORCID URL $orcid_url: " . $orcid_res->status_line . "\n");
    }
  }

  print STDERR " ... $lod_count lod data records read; $lod_processed_count records looked up at ORCID; $mismatch_count mismatches\n";
  ($mismatch_count == 0) ? exit (0) : exit (1);

#   Avoid "used only once" diagnostic
  undef($default_case_sensitive);
  undef ($default_strip_leading_and_trailing_blanks);
  undef ($default_given_name_match_length);
}

sub
match_em
{
  my ($orcid_family,$lod_family,$orcid_given,$lod_given,$temp);
  $orcid_family = $orcid_family_name;
  $lod_family = $lod_family_name;
#   NB: ORCID "given_name" field name is plural; BCO-DMO singular (from data field names)
  $orcid_given = $orcid_given_names;
  $lod_given = $lod_given_name;
  if ($strip_leading_and_trailing_blanks) {
    $orcid_family = &whitespace_strip($orcid_family);
    $lod_family = &whitespace_strip($lod_family);
    $orcid_given = &whitespace_strip($orcid_given);
    $lod_given = &whitespace_strip ($lod_given);
  }
  ($orcid_family_name eq "") && ($lod_family_name eq "") && return "No family name info";
  ($lod_family_name eq "") && return "Empty BCO-DMO family name";
  ($orcid_family_name eq "") && return "Empty ORCID family name";
  if ( ! $case_sensitive) {
    $orcid_family = lc($orcid_family);
    $lod_family = lc($lod_family);
    $orcid_given = lc($orcid_given);
    $lod_given = lc ($lod_given);
  }
  ($orcid_family eq $lod_family) || return "Family name mismatch";
  ($orcid_given eq $lod_given) && return "MATCH";
  ($given_name_match_length == -1) && return "Given name mismatch";
  ($given_name_match_length == 0) &&
        ($given_name_match_length = (length($orcid_given) < length($lod_given))? $orcid_given : $lod_given);
  ((substr($orcid_given,0,$given_name_match_length) eq substr($lod_given,0,$given_name_match_length))) ? 
        return "MATCH" : return "Given name mismatch";
}

sub whitespace_strip
#  Returns null if all whitespace, but consider that stripped string could be 0
{
  my ($strip,$dummy) = @_;
  (defined $strip && ! defined($dummy)) || &quit ("Internal error: whitespace_strip  not called w/1 arg");
  ($strip eq "") || ($strip =~ s/^\s*//);
  ($strip eq "") || ($strip =~ s/\s*$//);
  return $strip;
}

sub true_false
#  Returns $TRUE, $FALSE or $ILLEGAL, expected to be defined globally.  Last returned if
#  input string does not match 1,0,true,false,yes,no (case insensitive; 1st letter abbrev OK)
#  Numbers treated as 1 char strings
{
  my ($inp,$dummy) = @_;
  (defined $inp && ! defined($dummy)) || &quit ("Internal error: true_false  not called w/1 arg");
  ($inp eq "") && return $ILLEGAL;
  ($inp eq "1") && return $TRUE;
  ($inp eq "0") && return $FALSE;
  $inp = lc($inp);
  if (length($inp) == 1) {
    (($inp eq "t") || ($inp eq "y")) && return $TRUE;
    (($inp eq "f") || ($inp eq "n")) && return $FALSE;
  } else {
    (($inp eq "true") || ($inp eq "yes")) && return $TRUE;
    (($inp eq "false") || ($inp eq "no")) && return $FALSE;
  }
  return $ILLEGAL;
}

sub valid_number
{
#  See if a string is a valid number.	WJS  Apr 99
#	(mod Jul 05 to pre-test for most likely strings, on hypothesis
#	 that string test is quicker than exception testing.  WJS)
#  Idea is to turn warnings on, force a numeric calculation, trap
#    any resulting warning message, and see if it's appropriate.
#    Because it's only a warning, eval does not set $@ as it does for
#    worse errors.  Therefore, the fooling with signals...
#  Of course this breaks if the message changes.  Much better would
#    be to have a perl-callable strtod function...
#  The perl manual says that numbers match /[+-]\d*\.?\d*E[+-]\d+/
#    (when it was talking about library module BigFloat).  However, that
#    description clearly doesn't reflect the optional portions of numbers...
  my ($test_item) = @_;
  my ($number);
  
  ((defined $test_item) && ($test_item ne "")) || return 0;

#   Quick test - numbers
  ($number) = ($test_item =~ /^\s*(\d*\.?\d*)\s*$/);
  $number && ($number ne '.') && return 1;
#   Quick test - strings.  Will incorrectly reject non-decimal radix if such strings
#   can be represented without quoting characters.  Will correctly reject NaN
#   and Inf, but more rigorous test for those later in case we pull this quick test
#   Also, next test will incorrectly accept -Inf (more rigorous test, blah blah)
  ($test_item =~ /^[A-Za-z]*$/) && return 0;

  local ($numeric_flag) = 1;

  my ($old_val_warn) = $^W;
  $^W = 1;			# Turn on warnings

#   Used to have sub test $_[0] (the warning message) to see if it was
#   an "Argument .* not numeric" message.  Now think that if the eval gets
#   any kind of warning, there must be a problem with the putative number,
#   so just decide it's not a number.  Presumably if there were
#   a numeric warning (overflow? is this a fatal?), the this technique
#   would be incorrect.  If we know that numeric warnings have their
#   own signal, presumably we could trap that, too (and we'd get it before
#   __WARN__ or __&quit__?)
  local $SIG{__WARN__} = sub { $numeric_flag = 0; };

  eval '$test_item + 1';		# Anything that does arithmetic

  $old_val_warn || ($^W = 0);	# Reset warnings if appropriate
  $SIG{__WARN__} = 'DEFAULT';	# Return signal to normal behavior

#   NaN test
  $numeric_flag && ($test_item != $test_item) && ($numeric_flag = 0);
#   Inf test
  $numeric_flag && ($test_item == $test_item+1) && ($numeric_flag = 0);
#   -Inf test
  $numeric_flag && ($test_item == $test_item-1) && ($numeric_flag = 0);

  return $numeric_flag;
}

sub quit
{
  my ($temp,$errmsg1,$errmsg2);

  $errmsg1 = "";
  foreach (@_) {
    chomp ($temp = $_);
    $errmsg1 .= "$temp\n";
  }

  $errmsg2 = "This message issued " . localtime() . "\n";
  $version && ($errmsg2 .= "$version\n");

  die($errmsg1,$errmsg2);
}


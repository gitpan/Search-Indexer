package Search::Indexer;

use strict;
use warnings;
use Carp;
use BerkeleyDB;
use locale;
use Search::QueryParser;

our $VERSION = "0.70";

=head1 NAME

Search::Indexer - full-text indexer

=head1 SYNOPSIS

  use Search::Indexer;
  my $ix = new Search::Indexer(dir => $dir, writeMode => 1);
  foreach my $docId (keys %docs) {
    $ix->add($docId, $docs{$docId});
  }

  my $result = $ix->search('+word -excludedWord +"exact phrase");
  my @docIds = keys @{$result->{scores}};
  my $killedWords = join ", ", @{$result->{killedWords}};
  print scalar(@docIds), " documents found\n", ;
  print "words $killedWords were ignored during the search\n" if $killedWords;
  foreach my $docId (@docIds) {
    my $score = $result->{scores}{$docId};
    my $excerpts = join "\n", $ix->excerpts($docs{$docId}, $result->{regex});
    print "DOCUMENT $docId, score $score:\n$excerpts\n\n";
  }

  my $result2 = $ix->search('word1 AND (word2 OR word3) AND NOT word4');

  $ix->remove($someDocId, $docs{$someDocId});

=head1 DESCRIPTION

This module provides support for indexing a collection of documents,
for searching the collection, and displaying the sorted results, 
together with contextual excerpts of the original document.

=head2 Documents

As far as this module is concerned, a I<document> is just a buffer of
plain text, together with a unique identifying number. The caller is
responsible for supplying unique numbers, and for converting the
original source (HTML, PDF, whatever) into plain text. Documents could
also contain more information (other fields like date, author, Dublin
Core, etc.), but this must be handled externally, in a database or any
other store. A candidate for storing metadata about documents
could be L<File::Tabular|File::Tabular>, which uses the same
query parser.

=head2 Search syntax

Searching requests may include plain terms, "exact phrases", 
'+' or '-' prefixes, boolean operators and parentheses.
See L<Search::QueryParser> for details.

=head2 Index files

The indexer uses three files in BerkeleyDB format : a) a mapping from
words to wordIds; b) a mapping from wordIds to lists of documents ; c)
a mapping from pairs (docId, wordId) to lists of positions within the
document. This third file holds detailed information and therefore is
quite big ; but it allows us to quickly retrieve "exact phrases"
(sequences of adjacent words) in the document.

=head2 Indexing steps

Indexing of a document buffer goes through the following
steps :

=over

=item *

terms are extracted, according to the I<wregex> regular expression

=item *

extracted terms are normalized or filtered out
by the I<wfilter> callback function. This function can for example
remove accented characters, perform lemmatization, suppress
irrelevant terms (such as numbers), etc.

=item *

normalized terms are eliminated if they belong to
the I<stopwords> list (list of common words to exclude from the index).

=item *

remaining terms are stored, together with the positions where they
occur in the document.

=back

=head2 Limits

All ids are stored as unsigned 32-bit integers; therefore there is 
a limit of 4294967295 to the number of documents or to the number of 
different words.

=head2 Related modules

A short comparison with other CPAN indexing modules is
given in the L</"SEE ALSO"> section.

This module depends on L<Search::QueryParser> for analyzing requests and 
on L<BerkeleyDB> for storing the indexes.

This module was designed together with L<File::Tabular>.

=cut


sub addToScore (\$$);

use constant {

# max size of various ids
  MAX_DOC_ID  => 0xFFFFFFFF, # unsigned long (32 bits)
  MAX_POS_ID  => 0xFFFFFFFF, # position_id

# encodings for pack/unpack
  IXDPACK     => 'wC',       # docId : compressed int; freq : unsigned char
  IXDPACK_L   => '(wC)*',    # list of above
  IXPPACK     => 'w*',       # word positions : list of compressed ints
  IXPKEYPACK  => 'ww',       # key for ixp : (docId, wordId)

  WRITECACHESIZE => (1 << 24), # arbitrary big value; seems good enough but need tuning

# default values for args to new()
  DEFAULT     => {
    writeMode => 0,
    wregex    => qr/\w+/,
    wfilter   => sub { # default filter : lowercase and no accents
      my $word = lc($_[0]);
      $word =~ tr[�����������������������][caaaaeeeeiiiioooouuuuyy];
      return $word;
    },
    fieldname => '',

    ctxtNumChars => 35,
    maxExcerpts  => 5,
    preMatch     => "<b>",
    postMatch    => "</b>"
  }
};

=head1 METHODS

=over

=item C<new(arg1 =E<gt> expr1, ...)>

Creates an indexer (either for a new index, or for
accessing an existing index). Parameters are :

=over

=item dir

Directory for index files. and possibly for the stopwords file. 
Default is current directory

=item writeMode

Give a true value if you intend to write into the index.

=item wregex 

Regex for matching a word (C<qr/\w+/> by default).
Will affect both L<add> and L<search> method.
This regex should not contain any capturing parentheses.

=item wfilter

Ref to a callback sub that may normalize or eliminate a word.  Will
affect both L<add> and L<search> method.  The default wfilter
translates words in lower case and translates latin1 (iso-8859-1)
accented characters into plain characters.

=item stopwords

List of words that will be marked into the index as "words to exclude".
This should usually occur when creating a new index ; but nothing prevents
you to add other stopwords later. Since stopwords are stored in the
index, they need not be specified When opening an index for searches or 
updates.

The list may be supplied either as a ref to an array of scalars, or 
as a the name of a file containing the stopwords (full pathname
or filename relative to I<dir>).


=item fieldname

Will only affect the L<search> method.
Search queries are passed to a general parser
(see L<Search::QueryParser>). 
Then, before being applied to the present indexer module, 
queries are pruned of irrelevant items.
Query items are considered relevant if they have no
associated field name, or if the associated field name is
equal to this C<fieldname>.

=back

Below are some additional parameters that only affect the
L</excerpts> method.

=over

=item ctxtNumChars

Number of characters determining the size of contextual excerpts
return by the L</excerpts> method.
A I<contextual excerpt> is a part of the document text,
containg a matched word surrounded by I<ctxtNumChars> characters 
to the left and to the right. Default is 35.


=item maxExcerpts

Maximum number of contextual excerpts to retrieve per document.
Default is 5.

=item preMatch

String to insert in contextual excerpts before a matched word.
Default is C<"E<lt>bE<gt>">.

=item postMatch

String to insert in contextual excerpts after a matched word.
Default is C<"E<lt>/bE<gt>">.


=back

=cut

sub new {
  my $class = shift;
  my $args = ref $_[0] eq 'HASH' ? $_[0] : {@_};

  my $self = {};
  $self->{$_} = $args->{$_} || DEFAULT->{$_} 
    foreach qw(writeMode wregex wfilter fieldname 
	       ctxtNumChars maxExcerpts preMatch postMatch);

  my $dir = $args->{dir} || ".";

  # BerkeleyDB environment should allow us to do proper locking for 
  # concurrent access ; but seems to be incompatible with the 
  # -Cachesize argument, so I commented it out ... need to learn more about
  # BerkeleyDB ...
#   my $dbEnv = new BerkeleyDB::Env
#     -Home => $dir,
#     -Flags => DB_INIT_CDB | DB_INIT_MPOOL | DB_CDB_ALLDB |
#                 ($self->{writeMode} ? DB_CREATE : 0),
#     -Verbose => 1
#       or confess "new BerkeleyDB::Env : $^E  $BerkeleyDB::Error" ;

  # 3 index files :
  # ixw : word => wordId (or -1 for stopwords)
  # ixd : wordId => list of (docId, nOccur)
  # ixp : (wordId, docId) => list of positions of word in doc
  foreach my $ix (qw(ixw ixd ixp)) {
    tie %{$self->{$ix}}, 'BerkeleyDB::Hash', 
      -Filename => "$dir/$ix.bdb",
      # -Env => $dbEnv, # environment commented out, see explanation above
      -Flags => ($self->{writeMode} ? DB_CREATE : DB_RDONLY),

      ($self->{writeMode} ? (-Cachesize => WRITECACHESIZE) : ())
	  or confess "open $args->{dir}/$ix.bdb : $^E $BerkeleyDB::Error"

 ;
  }

  # optional list of stopwords may be given as a list or as a filename
  if ($args->{stopwords}) { 
    $self->{writeMode} or confess "must be in writeMode to specify stopwords";
    if (not ref $args->{stopwords}) { # if scalar, name of stopwords file
      open TMP, $args->{stopwords} or 
	($args->{dir} and open TMP, "$args->{dir}/$args->{stopwords}") or
	  confess "open stopwords file $args->{stopwords} : $^E ";
      local $/ = undef;
      my $buf = <TMP>;
      $args->{stopwords} = [$buf =~ /$self->{wregex}/g];
      close TMP;
    }
    foreach my $word (@{$args->{stopwords}}) {
      $self->{ixw}{$word} = -1;
    }
  }

  bless $self, $class;
}





=item C<add(docId, buf)>

Add a new document to the index.
I<docId> is the unique identifier for this doc
(the caller is responsible for uniqueness).
I<buf> is a scalar containing the text representation of this doc.

=cut

sub add {
  my $self = shift;
  my $docId = shift;
  # my $buf = shift; # using $_[0] instead for efficiency reasons

  confess "docId $docId is too large" if $docId > MAX_DOC_ID;

  my %positions;
  for (my $nwords = 1; $_[0] =~ /$self->{wregex}/g; $nwords++) {	

    my $word = $self->{wfilter}->($&) or next;
    my $wordId = $self->{ixw}{$word}  ||
      ($self->{ixw}{$word} = ++$self->{ixw}{_NWORDS}); # create new wordId
    push @{$positions{$wordId}}, $nwords if $wordId > 0; 
  }

  foreach my $wordId (keys %positions) { 
    my $occurrences = @{$positions{$wordId}};
    $occurrences = 255 if $occurrences > 255;

    $self->{ixd}{$wordId} .= pack(IXDPACK, $docId, $occurrences);
    my $ixpKey = pack IXPKEYPACK, $docId, $wordId;
    $self->{ixp}{$ixpKey} =  pack(IXPPACK, @{$positions{$wordId}});
  }

  $self->{ixd}{NDOCS} = 0  if not defined $self->{ixd}{NDOCS};
  $self->{ixd}{NDOCS} += 1;
}


=item C<remove(docId, buf)>

Removes a document from the index.
I<Buf> must be supplied again and should be identical to what was
supplied at the time the document was added.

=cut

sub remove {
  my $self = shift;
  my $docId = shift;
  # my $buf = shift; # using $_[0] instead for efficiency reasons

  my %words;
  for (my $nwords = 1; $_[0] =~ /$self->{wregex}/g; $nwords++) {	
    my $word = $self->{wfilter}->($&) or next;
    my $wordId = $self->{ixw}{$word} || 0;
    $words{$wordId} = 1 if $wordId > 0; 
  }

  foreach my $wordId (keys %words) {
    my %docs = unpack IXDPACK_L, $self->{ixd}{$wordId};
    delete $docs{$docId};
    $self->{ixd}{$wordId} = pack IXDPACK_L, %docs;
    my $ixpKey = pack IXPKEYPACK, $docId, $wordId;
    delete $self->{ixp}{$ixpKey};
  }

  $self->{ixd}{NDOCS} -= 1;
}



=item C<dump()>

Debugging function, prints indexed words with list of associated docs.

=cut

sub dump {
  my $self = shift;
  foreach my $word (sort keys %{$self->{ixw}}) {
    my $wordId = $self->{ixw}{$word};
    my %docs = unpack IXDPACK_L, $self->{ixd}{$wordId};
    print "$word : ", join (" ", keys %docs), "\n";
  }
}


=item C<search(queryString, implicitPlus)>

Searches the index.  See the L</SYNOPSIS> and L</DESCRIPTION> sections
above for short descriptions of query strings, or
L<Search::QueryParser> for details.  The second argument is optional ;
if true, all words without any prefix will implicitly take prefix '+'
(mandatory words).

The return value is a hash ref containing 

=over

=item scores

hash ref, where keys are docIds of matching documents, and values are
the corresponding computed scores.

=item killedWords

ref to an array of terms from the query string which were ignored
during the search (because they were filtered out or were stopwords)

=item regex

ref to a regular expression corresponding to all terms in the query
string. This will be useful if you later want to get contextual
excerpts from the found documents (see the L<excerpts> method).

=back

=cut


sub search {
  my $self = shift;
  my $query_string = shift;
  my $implicitPlus = shift;

  $self->{qp} ||= new Search::QueryParser;

  my $q = $self->{qp}->parse($query_string, $implicitPlus);
  my $killedWords = {};
  my $wordsRegexes = [];

  my $qt = $self->translateQuery($q, $killedWords, $wordsRegexes);

  my $tmp = {};
  $tmp->{$_} = 1 foreach @$wordsRegexes;
  my $strRegex = "\\b(?:" . join("|", keys %$tmp) . ")\\b";

  return {scores => $self->_search($qt), 
	  killedWords => [keys %$killedWords],
	  regex => qr/$strRegex/i};
}


sub _search {
  my $self = shift;
  my $q = shift;

  my $scores = undef;		# hash {doc1 => score1, doc2 => score2 ...}

  # 1) deal with mandatory subqueries

  foreach my $subQ ( @{$q->{'+'}} ) {
    my $sc =  $self->docsAndScores($subQ) or next;
    $scores = $sc and next if not $scores;  # if first result set, just store

    # otherwise, intersect with previous result set
    foreach my $docId (keys %$scores) {
      delete $scores->{$docId} and next if not defined $sc->{$docId};
      addToScore $scores->{$docId}, $sc->{$docId}; # otherwise
    }
  }

  my $noMandatorySubq = not $scores;

  # 2) deal with non-mandatory subqueries 

  foreach my $subQ (@{$q->{''}}) {
    my $sc =  $self->docsAndScores($subQ) or next;
    $scores = $sc and next if not $scores;  # if first result set, just store

    # otherwise, combine with previous result set
    foreach my $docId (keys %$sc) {
      if (defined $scores->{$docId}) { # docId was already there, add new score
	addToScore $scores->{$docId}, $sc->{$docId};
      }
      elsif ($noMandatorySubq){ # insert a new docId to the result set
	$scores->{$docId} = $sc->{$docId};
      }
      # else do nothing (ignore this docId)
    }
  }

  return undef if not $scores; # no results, no need to check negative subQ

  # 3) deal with negative subqueries (remove corresponding docs from results)

  foreach my $subQ (@{$q->{'-'}}) {
    my $negScores =  $self->docsAndScores($subQ) or next;
    delete $scores->{$_}  foreach keys %$negScores;
  }

  return $scores;
}



sub docsAndScores { # returns a hash {docId => score} or undef (no info)
  my $self = shift;
  my $subQ = shift;

  # recursive call to _search if $subQ is a parenthesized query
  return $self->_search($subQ->{value}) if $subQ->{op} eq '()';

  # otherwise, don't care about $subQ->{op} (assert $subQ->{op} eq ':')
  my $scores = undef;

  if (not ref $subQ->{value}) { # scalar value, match single word
    if ($subQ->{value} > -1) {    # if this is not a stopword
      $scores = {unpack IXDPACK_L, ($self->{ixd}{$subQ->{value}} || "")};
      my @k = keys %$scores;
      if (@k) {
	my $coeff = log(($self->{ixd}{NDOCS} + 1)/@k) * 100;
	$scores->{$_} = int($coeff * $scores->{$_}) foreach @k;
      }
    }
  }
  else {                        # list of words, match exact phrase
    my %pos;
    my $wordDelta = 0;
    foreach my $wordId (@{$subQ->{value}}) {
      my $sc = $self->docsAndScores({op=>':', value=>$wordId});
      if (not $scores) { # no previous result set
	if ($sc) {
	  $scores = $sc;
	  foreach my $docId (keys %$scores) {
	    my $ixpKey = pack IXPKEYPACK, $docId, $wordId;
	    $pos{$docId} = [unpack IXPPACK, $self->{ixp}{$ixpKey}];
	  }
	}
      }
      else { # combine with previous result set
        $wordDelta++; 
	foreach my $docId (keys %$scores) {
	  if ($sc) { # if we have info about current word (is not a stopword)
	    if (not defined $sc->{$docId}) { # current word not in current doc
	      delete $scores->{$docId};
	    }
	    else { # current word found in current doc, check if positions match
	      my $ixpKey = pack IXPKEYPACK, $docId, $wordId;
	      my @newPos = unpack IXPPACK, $self->{ixp}{$ixpKey};
	      $pos{$docId} = nearPositions($pos{$docId}, \@newPos, $wordDelta)
		and addToScore $scores->{$docId}, $sc->{$docId}
		  or delete $scores->{$docId};
	    }
	  }
	} # end foreach my $docId (keys %$scores)
      }
    } # end foreach my $wordId (@{$subQ->{value}})
  }
  return $scores;
}


sub nearPositions { 
  my ($set1, $set2, $wordDelta) = @_;
# returns the set of positions in $set2 which are "close enough" (<= $wordDelta)
# to positions in $set1. Assumption : input sets are sorted.


  my @result;
  my ($i1, $i2) = (0, 0); # indices into sets

  while ($i1 < @$set1 and $i2 < @$set2) {
    my $delta = $set2->[$i2] - $set1->[$i1];
    ++$i1 and next             if $delta > $wordDelta;
    push @result, $set2->[$i2] if $delta > 0;
    ++$i2;
  }
  return @result ? \@result : undef;
}



sub addToScore (\$$) { # first score arg gets "incremented" by the second arg
  my ($ptScore1, $score2) = @_;
  $$ptScore1 = 0 if not defined $$ptScore1;
  $$ptScore1 += $score2 ; # TODO : find better formula for score combination !
}


sub translateQuery { # replace words by ids, remove irrelevant subqueries
  my ($self, $q, $killedWords, $wordsRegexes) = @_;

  my $r = {};

  foreach my $k ('+', '-', '') {
    foreach my $subQ (@{$q->{$k}}) {

      # ignore items concerning other field names
      next if $subQ->{field} and $subQ->{field} ne $self->{fieldname};

      my $val = $subQ->{value};

      my $clone = undef;
      if ($subQ->{op} eq '()') {
	$clone = {op => '()', 
		  value => $self->translateQuery($val, $killedWords, $wordsRegexes)};
      }
      elsif ($subQ->{op} eq ':') {

	# get back all words parsed by QueryParser into a single string ..
	my $str = ref $val ? join(" ", @$val) : $val;

	# ..and resplit them according to our notion of "term"
	my @words = ($str =~ /$self->{wregex}/g);

	push @$wordsRegexes, join "\\W+", @words;
	push @$wordsRegexes, join "\\W+", map {$self->{wfilter}($_)} @words;
	
	# now translate into word ids
	foreach my $word (@words) {
	  my $wf = $self->{wfilter}->($word);
	  my $wordId = $wf ? ($self->{ixw}{$wf} || 0) : -1;
	  $killedWords->{$word} = 1 if $wordId < 0;
	  $word = $wordId;
	}

	$val = (@words>1) ? \@words :    # several words : return an array
	       (@words>0) ? $words[0] :  # just one word : return its id
               0;                        # no word : return 0 (means "no info")

	$clone = {op => ':', value=> $val};
      }
      push @{$r->{$k}}, $clone if $clone;
    }
  }

  return $r;
}



=item C<excerpts(buf, regex)>

Searches C<buf> for occurrences of C<regex>, 
extracts the occurences together with some context
(a number of characters to the left and to the right),
and highlights the occurences. See parameters C<ctxtNumChars>,
C<maxExcerpts>, C<preMatch>, C<postMatch> of the L</new> method.

=cut

sub excerpts {
  my $self = shift;
  # $_[0] : text buffer ; no copy for efficiency reason
  my $regex = $_[1];

  my $nc = $self->{ctxtNumChars};

  # find start end end positions of matching fragments
  my $matches = []; # array of refs to [start, end, number_of_matches]
  while ($_[0] =~ /$regex/g) {
    my ($start, $end) = ($-[0], $+[0]);
    if (@$matches and $start <= $matches->[-1][1] + $nc) {
      # merge with the last fragment if close enough
      $matches->[-1][1] = $end; # extend the end position
      $matches->[-1][2] += 1;   # increment the number of matches
    }
    else {
      push @$matches, [$start, $end, 1];
    }
  }

  foreach (@$matches) { # extend start and end positions by $self->{ctxtNumChars}
    $_->[0] = ($_->[0] < $nc) ? 0 : $_->[0] - $nc; 
    $_->[1] += $nc;
  }

  my $excerpts = [];
  foreach my $match (sort {$b->[2] <=> $a->[2]} @$matches) {
    last if @$excerpts >= $self->{maxExcerpts};
    my $x = substr($_[0], $match->[0], $match->[1] - $match->[0]); # extract
    $x =~ s/$regex/$self->{preMatch}$&$self->{postMatch}/g ;       # highlight
    push @$excerpts, "...$x...";
  }
  return $excerpts;
}

=back

=head1 TO DO

=over

=item *

Find a proper formula for combining scores from several terms.
Current implementation is ridiculously simple-minded (just an addition).
Also study the literature to improve the scoring formula.

=item *

Handle concurrency through BerkeleyDB locks.

=item *

Maybe put all 3 index files as subDatabases in one single file.

=item *

Fine tuning of cachesize and other BerkeleyDB parameters.

=item *

Compare performances with other packages.

=item *

More functionalities : add NEAR operator and boost factors.

=back



=head1 SEE ALSO

L<Search::FreeText> is nice and compact, but
limited in functionality (no +/- prefixes, no "exact phrase" search,
no parentheses).

L<Plucene> is a Perl port of the Java I<Lucene> search engine.
Plucene has probably every feature you will ever need, but requires
quite an investment to install and learn (more than 60 classes,
dependencies on lots of external modules). 
I haven't done any benchmarks yet to compare performance.


=cut

	

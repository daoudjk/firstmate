#!/usr/bin/env bash
# fm-hold-reason-lib.sh - the one reversible encoding of a captain-hold reason.
#
# tasks-axi stores a hold reason as one markdown line inside a parenthesised tag,
# so its own `hold` refuses parentheses and line breaks. A decision reason is
# ordinary prose, so bin/fm-captain-hold.sh encodes the reason where it writes
# it and every reader that shows it decodes it again, instead of banning the
# characters. Stored reasons use the reserved fm-hold-v1: prefix followed by
# base64-encoded UTF-8 text. Unmarked reasons are plain text. Readers decode only
# the hold-reason field, once, and keep line breaks in quoted output strings.
#
# Source this file; it defines functions only.

# fm_hold_reason_encode <reason>: print the storable form, no trailing newline.
fm_hold_reason_encode() {
  printf '%s' "$1" | perl -MMIME::Base64=encode_base64 -0777 -ne \
    'print "fm-hold-v1:", encode_base64($_, "")'
}

# fm_hold_reason_decode_stream [toon|markdown|json]: decode marked reason fields.
fm_hold_reason_decode_stream() {
  perl -MJSON::PP -MMIME::Base64=encode_base64,decode_base64 -MEncode=decode,FB_CROAK -e '
    use strict;
    use warnings;
    binmode STDIN, ":encoding(UTF-8)";
    binmode STDOUT, ":encoding(UTF-8)";
    my $format = shift;
    my $json = JSON::PP->new->allow_nonref;
    sub decode_reason {
      my ($value) = @_;
      return $value unless defined($value) && $value =~ /^fm-hold-v1:(.*)\z/s;
      my $payload = $1;
      my $bytes = decode_base64($payload);
      return $value unless encode_base64($bytes, "") eq $payload;
      # Historical literals with valid base64 and UTF-8 remain indistinguishable
      # from encoded reasons; malformed payloads retain their stored text.
      my $decoded = eval { decode("UTF-8", $bytes, FB_CROAK) };
      return $@ ? $value : $decoded;
    }
    sub decode_field {
      my ($raw) = @_;
      my $value = $raw =~ /^"/ ? $json->decode($raw) : $raw;
      my $decoded = decode_reason($value);
      return $decoded eq $value ? $raw : $json->encode($decoded);
    }
    if ($format eq "json") {
      local $/;
      my $snapshot = $json->decode(<STDIN>);
      for my $record (@{$snapshot->{records}}) {
        $record->{hold_reason} = decode_reason($record->{hold_reason})
          if exists $record->{hold_reason};
      }
      print $json->encode($snapshot), "\n";
      exit;
    }
    my ($column, $task);
    while (my $line = <STDIN>) {
      if ($format eq "markdown") {
        $line =~ s{^([-*] .*\(hold:\s*)(fm-hold-v1:[A-Za-z0-9+/]*={0,2})(\).*)$}
          {$1 . decode_field($2) . $3}e;
      } elsif ($line =~ /^tasks\[\d+\]\{([^}]*)\}:\n?$/) {
        my @names = split /,/, $1;
        ($column) = grep { $names[$_] eq "hold_reason" } 0 .. $#names;
        $task = 0;
      } elsif (defined($column) && $line =~ /^  (.*)\n?$/) {
        my @fields = $1 =~ /("(?:[^"\\]|\\.)*"|[^,]+)/g;
        $fields[$column] = decode_field($fields[$column]);
        $line = "  " . join(",", @fields) . "\n";
      } elsif ($task && $line =~ /^  hold_reason: (.*)\n?$/) {
        $line = "  hold_reason: " . decode_field($1) . "\n";
      } elsif ($line !~ /^  /) {
        $column = undef;
        $task = $line eq "task:\n";
      }
      print $line;
    }
  ' "${1:-toon}"
}

# fm_hold_reason_bound_stream <max-chars> <toon|markdown> <pointer-format>:
# bound DECODED hold-reason fields for display, after fm_hold_reason_decode_stream.
# This is a display projection only: the stored reason is never read back from
# this output, and the full text stays one command away. A reason longer than
# <max-chars> user-perceived characters (Unicode grapheme clusters, so a
# multi-byte character or combining sequence is never split) keeps its first
# <max-chars> characters exactly and gains one explicit marker naming the shown
# and total counts plus the full-record pointer, built by substituting the row's
# task id for %s in <pointer-format>. Reasons at or under the bound, every other
# field, every row, and every non-row line pass through byte-for-byte; nothing
# is summarized or rewritten. A tasks-axi row whose quoted fields do not
# tokenize into exactly its header's column count, or whose id cannot be read,
# is left whole rather than guessed at, so a format surprise costs bytes, never
# a row or a wrong pointer. A <max-chars> of 0 disables bounding.
fm_hold_reason_bound_stream() {
  perl -MJSON::PP -e '
    use strict;
    use warnings;
    binmode STDIN, ":encoding(UTF-8)";
    binmode STDOUT, ":encoding(UTF-8)";
    my ($max, $format, $pointer) = @ARGV;
    $max = 0 unless defined($max) && $max =~ /^[0-9]+\z/;
    my $json = JSON::PP->new->allow_nonref->canonical;
    sub bound {
      my ($text, $id) = @_;
      return undef unless $max > 0 && defined $text;
      my @graphemes = $text =~ /(\X)/g;
      my $total = scalar @graphemes;
      return undef if $total <= $max;
      my $where = $pointer;
      $where =~ s/%s/$id/g;
      return join("", @graphemes[0 .. $max - 1])
        . " [truncated $max/$total chars; full: $where]";
    }
    sub field_value {
      my ($raw) = @_;
      return $raw !~ /^"/ ? $raw : eval { $json->decode($raw) };
    }
    my ($reason_col, $id_col, $columns);
    while (my $line = <STDIN>) {
      if ($format eq "markdown") {
        if ($line =~ /^([-*][ \t]+(?:\[[ xX]\][ \t]+(\S+)|\*\*([^*]+)\*\*)[ \t]+-[ \t].*?\(hold:[ \t]*)("(?:[^"\\]|\\.)*"|(?<plain>(?:[^()]|\((?&plain)\))*))([ \t]*\).*)$/s) {
          my ($head, $id, $reason, $tail) = ($1, defined $2 ? $2 : $3, $4, $6);
          my $value = field_value($reason);
          my $cut = bound(defined $value ? $value : $reason, $id);
          if (defined $cut) {
            $cut = $json->encode($cut) if defined($value) && $reason =~ /^"/;
            $line = $head . $cut . $tail;
          }
        }
      } elsif ($line =~ /^[A-Za-z_]+\[\d+\]\{([^}]*)\}:\n?\z/) {
        my @names = split /,/, $1;
        ($reason_col) = grep { $names[$_] eq "hold_reason" } 0 .. $#names;
        ($id_col) = grep { $names[$_] eq "id" } 0 .. $#names;
        $reason_col = undef unless defined $id_col;
        $columns = scalar @names;
      } elsif (defined($reason_col) && $line =~ /^  (.*?)\n?\z/s) {
        my $row = $1;
        my @fields = $row =~ /("(?:[^"\\]|\\.)*"|[^,]+)/g;
        if (@fields == $columns && join(",", @fields) eq $row) {
          my $id = field_value($fields[$id_col]);
          my $value = field_value($fields[$reason_col]);
          my $cut = (defined $id && defined $value && $id !~ /\s/) ? bound($value, $id) : undef;
          if (defined $cut) {
            $fields[$reason_col] = $json->encode($cut);
            $line = "  " . join(",", @fields) . "\n";
          }
        }
      } elsif ($line !~ /^  /) {
        $reason_col = undef;
      }
      print $line;
    }
  ' "${1:-0}" "${2:-toon}" "${3:-%s}"
}

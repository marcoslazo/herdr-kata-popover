#!/usr/bin/env bash
# Text transforms for the detail pane, split out of detail.sh so they can be
# exercised directly. Sourcing this file must not do anything observable — the
# tests source it, and detail.sh sources it before it owns a terminal.
#
# Both functions are perl programs with real edge cases (escape sequences that
# must not be counted, split, or reordered). tests/render.bats covers them.

# Wrap kata refs in OSC 8 links pointing back at our own handler.
#
# kata short ids are four lowercase base32 characters (q7xm, r4tz), which is
# far too loose to match in free text: shas, words and hex all collide. So only
# unambiguous forms are linked:
#
#   <project>#<id>   a qualified ref, anywhere (detail.sh renders links this way)
#   issue=<id>       kata's --agent output; resolved against KATA_PROJECT
#
# The lookbehind skips refs already inside a URL so existing links survive.
#
# Targets must be http(s): Herdr only turns http/https OSC 8 targets into click
# targets and consults link_handlers afterwards. kata.invalid is reserved by
# RFC 2606, so a click that misses the plugin cannot reach a real site.
#
# Underline only, no colour of our own: an SGR reset here would drop whatever
# colour the surrounding text already had for the rest of the line.
linkify() {
  KATA_PROJECT="${KATA_PROJECT:-}" perl -CSD -pe '
    BEGIN { $proj = $ENV{KATA_PROJECT} }
    sub lnk { my ($p, $id, $txt) = @_;
      my $path = length($p) ? "$p/$id" : $id;
      "\e]8;;https://kata.invalid/$path\e\\\e[4m$txt\e[24m\e]8;;\e\\" }
    # Stash escape sequences first, so an SGR directly before a ref does not
    # defeat the lookbehind and existing OSC 8 targets are never rewritten.
    my @esc;
    s/(\e\[[0-9;]*[A-Za-z]|\e\]8;;[^\e]*\e\\)/push @esc, $1; "\x00" . $#esc . "\x01"/ge;
    s{(?<![\w/.#-])([A-Za-z0-9][A-Za-z0-9._-]*)#([a-z0-9]{4,12})(?![\w-])}
     {lnk($1, $2, "$1#$2")}ge;
    s{(?<![\w/.-])issue=([a-z0-9]{4,12})(?![\w-])}
     {"issue=" . lnk($proj, $1, $1)}ge;
    s/\x00(\d+)\x01/$esc[$1]/g;
  '
}

# Re-wrap to the pane width. Escape sequences have no width, so a naive fold
# counts them as visible characters, wraps far too early, and can slice a
# sequence in half.
#
# Breaks on spaces only, so refs stay intact and clickable, and continuation
# lines keep the original indent.
wrapansi() {
  perl -CSD -e '
    my $w = shift(@ARGV) || 80;
    $w = 20 if $w < 20;
    while (my $line = <STDIN>) {
      chomp $line;
      my ($indent) = $line =~ /^(\s*)/;
      $indent = "" if length($indent) > $w - 10;
      my ($out, $col, $first) = ("", 0, 1);
      for my $tok (split /(\s+)/, $line) {
        next if $tok eq "";
        my $vis = $tok;
        $vis =~ s/\e\]8;;[^\e]*\e\\//g;
        $vis =~ s/\e\[[0-9;]*[A-Za-z]//g;
        my $len = length($vis);
        if ($tok =~ /^\s+$/) {
          if ($col + $len <= $w) { $out .= $tok; $col += $len }
          next;
        }
        if ($col + $len > $w && !$first) {
          $out =~ s/[ \t]+$//;
          $out .= "\n" . $indent;
          $col = length($indent);
        }
        $out .= $tok; $col += $len; $first = 0;
      }
      print $out, "\n";
    }
  ' "$1"
}

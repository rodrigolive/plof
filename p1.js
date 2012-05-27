use constant true => 1;
do {
  my ( $hh, $i, $square, $xx );
  $square = sub { my ( $x )=@_;
    return 10;
  };
  if (true) {
    $xx = 10;
  }
  $hh = {
    aa=> 11,
    bb=> 12
  };
  $xx = (sub {
    my ( $_results );
    $_results = [];
    for ($i = 1; $i <= 10; $i++) {
      push(@{ $_results || [] }, i + 2);
    }
    return $_results;
  })->();
  eval {
    say("hello");
  } if ($@) {}
};

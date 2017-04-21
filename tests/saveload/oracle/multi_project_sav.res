[kernel] Parsing share/libc/__fc_builtin_for_normalization.i (no preprocessing)
[kernel] Parsing tests/saveload/multi_project.i (no preprocessing)
[scf] beginning constant propagation
[value] Analyzing a complete application starting at main
[value] Computing initial state
[value] Initial state computed
[value:initial-state] Values of globals at initialization
  
[value] computing for function f <- main.
        Called from tests/saveload/multi_project.i:14.
[value] Recording results for f
[value] Done for function f
tests/saveload/multi_project.i:15:[value] assertion got status valid.
[value] Recording results for main
[value] done for function main
/* Generated by Frama-C */
int f(int x)
{
  int __retres;
  __retres = 4;
  return __retres;
}

int main(void)
{
  int __retres;
  int x = 2;
  int y = f(2);
  /*@ assert y ≡ 4; */ ;
  __retres = 8;
  return __retres;
}


[scf] constant propagation done

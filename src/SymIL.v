(** This file implements symbolic evaluation for the
 ** language defined in IL.v
 **)
Require Import Word.
Require Import PropX.
Require Import Expr SepExpr.
Require Import Prover.
Require Import Env.
Require Structured SymEval.
Import List.

Require Import IL SepIL ILEnv.

Set Implicit Arguments.
Set Strict Implicit.

(** The Symbolic Evaluation Interfaces *)
Module MEVAL := SymEval.SymbolicEvaluator SH.

Section typed.
  Variable types : list type.
  Variables pcT stT : tvar.

  (** Symbolic registers **)
  Definition SymRegType : Type :=
    (expr types * expr types * expr types)%type.

  (** Symbolic State **)
  Record SymState : Type :=
  { SymMem   : option (SH.SHeap types)
  ; SymRegs  : SymRegType
  ; SymPures : list (expr types)
  }.

  (** Register accessor functions **)
  Definition sym_getReg (r : reg) (sr : SymRegType) : expr types :=
    match r with
      | Sp => fst (fst sr)
      | Rp => snd (fst sr)
      | Rv => snd sr
    end.

  Definition sym_setReg (r : reg) (v : expr types) (sr : SymRegType) : SymRegType :=
    match r with
      | Sp => (v, snd (fst sr), snd sr)
      | Rp => (fst (fst sr), v, snd sr)
      | Rv => (fst sr, v)
    end.
  
  (** These the reflected version of the IL, it essentially 
   ** replaces all uses of W with expr types so that the value
   ** can be inspected.
   **)
  Inductive sym_loc :=
  | SymReg : reg -> sym_loc
  | SymImm : expr types -> sym_loc
  | SymIndir : reg -> expr types -> sym_loc.

  (* Valid targets of assignments *)
  Inductive sym_lvalue :=
  | SymLvReg : reg -> sym_lvalue
  | SymLvMem : sym_loc -> sym_lvalue.
  
  (* Operands *)
  Inductive sym_rvalue :=
  | SymRvLval : sym_lvalue -> sym_rvalue
  | SymRvImm : expr types -> sym_rvalue
  | SymRvLabel : label -> sym_rvalue.

  (* Non-control-flow instructions *)
  Inductive sym_instr :=
  | SymAssign : sym_lvalue -> sym_rvalue -> sym_instr
  | SymBinop : sym_lvalue -> sym_rvalue -> binop -> sym_rvalue -> sym_instr.

  Inductive sym_assert :=
  | SymAssertCond : sym_rvalue -> test -> sym_rvalue -> option bool -> sym_assert.

  Definition istream : Type := list ((list sym_instr * option state) + sym_assert).
End typed.

Section stateD.
  Notation pcT := (tvType 0).
  Notation tvWord := (tvType 0).
  Notation stT := (tvType 1).
  Notation tvState := (tvType 2).
  Notation tvTest := (tvType 3).
  Notation tvReg := (tvType 4).

  Variable types' : list type.
  Notation TYPES := (repr bedrock_types_r types').
  Variable funcs : functions TYPES.
  Variable sfuncs : SEP.predicates TYPES.

  Definition stateD (uvars vars : env TYPES) cs (stn_st : IL.settings * state) (ss : SymState TYPES) : Prop :=
    let (stn,st) := stn_st in
    match ss with
      | {| SymMem := m ; SymRegs := (sp, rp, rv) ; SymPures := pures |} =>
        match 
          exprD funcs uvars vars sp tvWord ,
          exprD funcs uvars vars rp tvWord ,
          exprD funcs uvars vars rv tvWord
          with
          | Some sp , Some rp , Some rv =>
            Regs st Sp = sp /\ Regs st Rp = rp /\ Regs st Rv = rv
          | _ , _ , _ => False
        end
        /\ match m with 
             | None => True
             | Some m => 
               PropX.interp cs (SepIL.SepFormula.sepFormula (SEP.sexprD funcs sfuncs uvars vars (SH.sheapD m)) stn_st)%PropX
           end
        /\ AllProvable funcs uvars vars (match m with 
                                           | None => pures
                                           | Some m => pures ++ SH.pures m
                                         end)
    end.

  Definition qstateD (uvars vars : env TYPES) cs (stn_st : IL.settings * state) (qs : SymEval.Quant) (ss : SymState TYPES) : Prop :=
    SymEval.quantD vars uvars qs (fun vars_env meta_env => stateD meta_env vars_env cs stn_st ss).

End stateD.

Implicit Arguments sym_loc [ ].
Implicit Arguments sym_lvalue [ ].
Implicit Arguments sym_rvalue [ ].
Implicit Arguments sym_instr [ ].
Implicit Arguments sym_assert [ ].

Section Denotations.
  Variable types' : list type.
  Notation TYPES := (repr bedrock_types_r types').

  Notation pcT := (tvType 0).
  Notation tvWord := (tvType 0).
  Notation stT := (tvType 1).
  Notation tvState := (tvType 2).
  Notation tvTest := (tvType 3).
  Notation tvReg := (tvType 4).


  (** Denotation/reflection functions give the meaning of the reflected syntax *)
  Variable funcs' : functions TYPES.
  Notation funcs := (repr (bedrock_funcs_r types') funcs').
  Variable sfuncs : SEP.predicates TYPES.
  Variable uvars vars : env TYPES.
  
  Definition sym_regsD (rs : SymRegType TYPES) : option regs :=
    match rs with
      | (sp, rp, rv) =>
        match 
          exprD funcs uvars vars sp tvWord ,
          exprD funcs uvars vars rp tvWord ,
          exprD funcs uvars vars rv tvWord 
          with
          | Some sp , Some rp , Some rv =>
            Some (fun r => 
              match r with
                | Sp => sp
                | Rp => rp
                | Rv => rv
              end)
          | _ , _ , _ => None
        end
    end.

  Definition sym_locD (s : sym_loc TYPES) : option loc :=
    match s with
      | SymReg r => Some (Reg r)
      | SymImm e =>
        match exprD funcs uvars vars e tvWord with
          | Some e => Some (Imm e)
          | None => None
        end
      | SymIndir r o =>
        match exprD funcs uvars vars o tvWord with
          | Some o => Some (Indir r o)
          | None => None
        end
    end.

  Definition sym_lvalueD (s : sym_lvalue TYPES) : option lvalue :=
    match s with
      | SymLvReg r => Some (LvReg r)
      | SymLvMem l => match sym_locD l with
                        | Some l => Some (LvMem l)
                        | None => None
                      end
    end.

  Definition sym_rvalueD (r : sym_rvalue TYPES) : option rvalue :=
    match r with
      | SymRvLval l => match sym_lvalueD l with
                         | Some l => Some (RvLval l)
                         | None => None
                       end
      | SymRvImm e => match exprD funcs uvars vars e tvWord with
                        | Some l => Some (RvImm l)
                        | None => None
                      end
      | SymRvLabel l => Some (RvLabel l)
    end.

  Definition sym_instrD (i : sym_instr TYPES) : option instr :=
    match i with
      | SymAssign l r =>
        match sym_lvalueD l , sym_rvalueD r with
          | Some l , Some r => Some (Assign l r)
          | _ , _ => None
        end
      | SymBinop lhs l o r =>
        match sym_lvalueD lhs , sym_rvalueD l , sym_rvalueD r with
          | Some lhs , Some l , Some r => Some (Binop lhs l o r)
          | _ , _ , _ => None
        end
    end.

  Fixpoint sym_instrsD (is : list (sym_instr TYPES)) : option (list instr) :=
    match is with
      | nil => Some nil
      | i :: is => 
        match sym_instrD i , sym_instrsD is with
          | Some i , Some is => Some (i :: is)
          | _ , _ => None
        end
    end.

  Fixpoint istreamD (is : istream TYPES) (stn : settings) (st : state) (res : option state) : Prop :=
    match is with
      | nil => Some st = res
      | inl (ins, st') :: is => 
        match sym_instrsD ins with
          | None => False
          | Some ins => 
            match st' with
              | None => evalInstrs stn st ins = None
              | Some st' => evalInstrs stn st ins = Some st' /\ istreamD is stn st' res
            end
        end
      | inr asrt :: is =>
        match asrt with
          | SymAssertCond l t r t' => 
            match sym_rvalueD l , sym_rvalueD r with
              | Some l , Some r =>
                match t' with
                  | None => 
                    Structured.evalCond l t r stn st = None
                  | Some t' =>
                    Structured.evalCond l t r stn st = Some t' /\ istreamD is stn st res
                end
              | _ , _ => False
            end
        end
    end.

  Section SymEvaluation.
    Variable Prover : ProverT TYPES.
    Variable meval : MEVAL.MemEvaluator TYPES.

    Section with_facts.
    Variable Facts : Facts Prover.

    Definition sym_evalLoc (lv : sym_loc TYPES) (ss : SymState TYPES) : expr TYPES :=
      match lv with
        | SymReg r => sym_getReg r (SymRegs ss)
        | SymImm l => l
        | SymIndir r w => fPlus (sym_getReg r (SymRegs ss)) w
      end.

    Definition sym_evalLval (lv : sym_lvalue TYPES) (val : expr TYPES) (ss : SymState TYPES)
      : option (SymState TYPES) :=
      match lv with
        | SymLvReg r =>
          Some {| SymMem := SymMem ss 
                ; SymRegs := sym_setReg r val (SymRegs ss)
                ; SymPures := SymPures ss
                |}
        | SymLvMem l => 
          let l := sym_evalLoc l ss in
            match SymMem ss with
              | None => None
              | Some m =>
                match MEVAL.swrite_word meval _ Facts l val m with
                  | Some m =>
                    Some {| SymMem := Some m
                          ; SymRegs := SymRegs ss
                          ; SymPures := SymPures ss
                          |}
                  | None => None
                end
            end
      end.

    Definition sym_evalRval (rv : sym_rvalue TYPES) (ss : SymState TYPES) : option (expr TYPES) :=
      match rv with
        | SymRvLval (SymLvReg r) =>
          Some (sym_getReg r (SymRegs ss))
        | SymRvLval (SymLvMem l) =>
          let l := sym_evalLoc l ss in
            match SymMem ss with
              | None => None
              | Some m => 
                MEVAL.sread_word meval _ Facts l m
            end
        | SymRvImm w => Some w 
        | SymRvLabel l => None (* TODO: can we use labels? it seems like we need to reflect these as words. *)
        (* an alternative would be to reflect these as a function call that does the positioning...
         * - it isn't clear that this can be done since the environment would need to depend on the settings.
         *)
        (*Some (Expr.Const (TYPES := TYPES) (t := tvType 2) l) *)
      end.

    Definition sym_assertTest (l : sym_rvalue TYPES) (t : test) (r : sym_rvalue TYPES) (ss : SymState TYPES) (res : bool) 
      : option (expr TYPES) :=
      let '(l, t, r) := 
        if res then (l, t, r)
        else match t with
               | IL.Eq => (l, IL.Ne, r)
               | IL.Ne => (l, IL.Eq, r)
               | IL.Lt => (r, IL.Le, l)
               | IL.Le => (r, IL.Lt, l)
             end
      in
      match sym_evalRval l ss , sym_evalRval r ss with
        | Some l , Some r =>
          Some match t with
                 | IL.Eq => Expr.Equal tvWord l r
                 | IL.Ne => Expr.Not (Expr.Equal tvWord l r)
                 | IL.Lt => Expr.Func 4 (l :: r :: nil)
                 | IL.Le => Expr.Not (Expr.Func 4 (r :: l :: nil))
          end
        | _ , _ => None
      end.

    Definition sym_evalInstr (i : sym_instr TYPES) (ss : SymState TYPES) : option (SymState TYPES) :=
      match i with 
        | SymAssign lv rv =>
          match sym_evalRval rv ss with
            | None => None
            | Some rv => sym_evalLval lv rv ss
          end
        | SymBinop lv l o r =>
          match sym_evalRval l ss , sym_evalRval r ss with
            | Some l , Some r => 
              let v :=
                match o with
                  | Plus  => fPlus
                  | Minus => fMinus
                  | Times => fMult
                end _ l r
                in
                sym_evalLval lv v ss
            | _ , _ => None
          end
      end.

    Fixpoint sym_evalInstrs (is : list (sym_instr TYPES)) (ss : SymState TYPES) 
      : SymState TYPES + (SymState TYPES * list (sym_instr TYPES)) :=
      match is with
        | nil => inl ss
        | i :: is =>
          match sym_evalInstr i ss with
            | None => inr (ss, i :: is)
            | Some ss => sym_evalInstrs is ss
          end
      end.
    End with_facts.
    
    Variable learnHook : MEVAL.LearnHook TYPES (SymState TYPES).

    Inductive SymResult : Type :=
    | Safe      : SymEval.Quant -> SymState TYPES -> SymResult
(*    | Unsafe    : SymEval.Quant -> SymResult *)
    | SafeUntil : SymEval.Quant -> SymState TYPES -> istream TYPES -> SymResult. 

    Fixpoint sym_evalStream (facts : Facts Prover) (is : istream TYPES) (qs : SymEval.Quant) (u g : variables) 
      (ss : SymState TYPES) : SymResult :=
      match is with
        | nil => Safe qs ss
        | inl (ins, st) :: is =>
          match sym_evalInstrs facts ins ss with
            | inr (ss,rm) => SafeUntil qs ss (inl (rm, st) :: is)
            | inl ss => sym_evalStream facts is qs u g ss
          end
        | inr asrt :: is =>
          match asrt with
            | SymAssertCond l t r (Some res) =>
              match sym_assertTest facts l t r ss res with
                | Some sp =>
                  let facts' := Learn Prover facts (sp :: nil) in 
                  let ss' := 
                    {| SymRegs := SymRegs ss 
                     ; SymMem := SymMem ss
                     ; SymPures := sp :: SymPures ss
                     |}
                  in
                  let (ss', qs') := learnHook Prover u g ss' facts' (sp :: nil) in
                  sym_evalStream facts' is (SymEval.appendQ qs' qs) (u ++ SymEval.gatherAll qs') (g ++ SymEval.gatherEx qs') ss'
                | None => SafeUntil qs ss (inr asrt :: is)
              end
            | SymAssertCond l t r None =>
              match sym_evalRval facts l ss , sym_evalRval facts r ss with
                | None , _ => SafeUntil qs ss (inr asrt :: is)
                | _ , None => SafeUntil qs ss (inr asrt :: is)
                | Some _ , Some _ => sym_evalStream facts is qs u g ss 
              end
          end
      end.
  End SymEvaluation.
End Denotations.

Definition IL_stn_st : Type := (IL.settings * IL.state)%type.

Section spec_functions.
  Variable ts : list type.
  Let types := repr core_bedrock_types_r ts.

  Local Notation "'pcT'" := (tvType 0).
  Local Notation "'tvWord'" := (tvType 0).
  Local Notation "'stT'" := (tvType 1).

  Definition IL_mem_satisfies (cs : PropX.codeSpec (tvarD types pcT) (tvarD types stT)) 
    (P : ST.hprop) (stn_st : (tvarD types stT)) : Prop :=
    PropX.interp cs (SepIL.SepFormula.sepFormula P stn_st).
  
  Definition IL_ReadWord : IL_stn_st -> tvarD types tvWord -> option (tvarD types tvWord) :=
    (fun stn_st => IL.ReadWord (fst stn_st) (Mem (snd stn_st))).
  Definition IL_WriteWord : IL_stn_st -> tvarD types tvWord -> tvarD types tvWord -> option IL_stn_st :=
    (fun stn_st p v => 
      let (stn,st) := stn_st in
        match IL.WriteWord stn (Mem st) p v with
          | None => None
          | Some m => Some (stn, {| Regs := Regs st ; Mem := m |})
        end).

  Theorem IL_mem_satisfies_himp : forall cs P Q stn_st,
    IL_mem_satisfies cs P stn_st ->
    ST.himp P Q ->
    IL_mem_satisfies cs Q stn_st.
  Proof.
    unfold IL_mem_satisfies; intros.
    eapply sepFormula_himp_imply in H0.
    2: eapply (refl_equal stn_st). unfold PropXRel.PropX_imply in *.
    eapply PropX.Imply_E; eauto. 
  Qed.
  Theorem IL_mem_satisfies_pure : forall cs p Q stn_st,
    IL_mem_satisfies cs (ST.star (ST.inj p) Q) stn_st ->
    p.
  Proof.
    unfold IL_mem_satisfies; intros.
    rewrite sepFormula_eq in H. 
    PropXTac.propxFo; auto.
  Qed.

  Section ForWord.
    Local Notation "'ptrT'" := (tvType 0) (only parsing).
    Local Notation "'valT'" := (tvType 0) (only parsing).

    Variable mep : MEVAL.PredEval.MemEvalPred types.
    Variable pred : SEP.predicate types.
    Variable funcs : functions types.

    Hypothesis read_pred_correct : forall P (PE : ProverT_correct P funcs),
      forall args uvars vars cs facts pe p ve stn st,
        MEVAL.PredEval.pred_read_word mep P facts args pe = Some ve ->
        Valid PE uvars vars facts ->
        exprD funcs uvars vars pe ptrT = Some p ->
        match 
          applyD (exprD funcs uvars vars) (SEP.SDomain pred) args _ (SEP.SDenotation pred)
          with
          | None => False
          | Some p => 
            interp cs (p stn st) (* (*ST.satisfies cs p stn st*)
            IL_mem_satisfies cs p (stn, st) *)
        end ->
        match exprD funcs uvars vars ve valT with
          | Some v =>
            smem_get_word (implode stn) p st = Some v
            (*ST.HT.smem_get_word (implode stn) p st = Some v *)
          | _ => False
        end.

    Hypothesis write_pred_correct : forall P (PE : ProverT_correct P funcs),
      forall args uvars vars cs facts pe p ve v stn st args',
        MEVAL.PredEval.pred_write_word mep P facts args pe ve = Some args' ->
        Valid PE uvars vars facts ->
        exprD funcs uvars vars pe ptrT = Some p ->
        exprD funcs uvars vars ve valT = Some v ->
        match
          applyD (@exprD _ funcs uvars vars) (SEP.SDomain pred) args _ (SEP.SDenotation pred)
          with
          | None => False
          | Some p => interp cs (p stn st)
        end ->
        match 
          applyD (@exprD _ funcs uvars vars) (SEP.SDomain pred) args' _ (SEP.SDenotation pred)
          with
          | None => False
          | Some pr => 
            match smem_set_word (explode stn) p v st with
              | None => False
              | Some sm' => interp cs (pr stn sm')
            end
        end.

    Theorem interp_satisfies : forall cs P stn st,
      PropX.interp cs (SepIL.SepFormula.sepFormula P (stn,st)) <->
      (BedrockSepHeap.models (memoryIn (IL.Mem st)) (IL.Mem st) /\ interp cs (P stn (memoryIn (IL.Mem st)))). 
    Proof.
      unfold IL_mem_satisfies. clear. intros. rewrite sepFormula_eq. unfold sepFormula_def. simpl in *.      
      intuition. eapply memoryIn_sound. 
    Qed.

    Require Import Reflection.

    Ltac think :=
      repeat match goal with
               | [ H : exists x , _ |- _ ] => destruct H
               | [ H : _ /\ _ |- _ ] => destruct H
             end.

(*
    (** TODO: find a better place for these! **)
    Lemma mem_set_relevant_memoryIn : forall m p v m',
      H.mem_set m p v = Some m' ->
      relevant (memoryIn m) = relevant (memoryIn m').
    Proof.
      clear. do 5 intro. unfold relevant, memoryIn, HT.memoryIn. generalize H.all_addr.
      induction l; simpl; auto; intros.
      unfold H.mem_set, WriteByte, H.mem_get, ReadByte in *.
      destruct (equiv_dec a p); unfold equiv in *; subst.
      destruct (m p); try congruence. inversion H; simpl in *. destruct (weq p p); try congruence.

      destruct (m p); try congruence. inversion H. subst.
      destruct (weq a p). subst; congruence.
      rewrite IHl. reflexivity.
    Qed.


    Lemma mem_set_word_relevant_memoryIn : forall (p v : Memory.W) x1 m p0,
      Memory.mem_set_word H.addr H.mem H.footprint_w H.mem_set p0 p v m =
      Some x1 -> relevant (memoryIn x1) = relevant (memoryIn m).
    Proof.
      clear.
      unfold Memory.mem_set_word; do 2 intro. destruct (H.footprint_w p).
      destruct p1. destruct p1. do 2 destruct p0. destruct p1. 
      repeat match goal with
               | [ |- match ?X with _ => _ end = _ -> _ ] => case_eq X; try congruence; intro; intro
               | [ |- _ -> _ ] => intros
               | [ H : H.mem_set _ _ _ = Some _ |- _ ] =>
                 eapply mem_set_relevant_memoryIn in H
             end.
      congruence.
    Qed.
*)

    (** TODO: Move to SepIL. **)
    Require Import PropXRel PropXTac.

    Lemma mep_correct : @MEVAL.PredEval.MemEvalPred_correct types pcT stT (IL.settings * IL.state)
      (tvType 0) (tvType 0) IL_mem_satisfies IL_ReadWord IL_WriteWord mep pred funcs.
    Proof.
      constructor; intros; destruct stn_st as [ stn st ];
        match goal with
          | [ H : match ?X with _ => _ end |- _ ] =>
            revert H; case_eq X; intros; try contradiction
        end.
      { eapply interp_satisfies in H3. think.
        apply satisfies_star in H4. think.
        eapply read_pred_correct in H; eauto.
        Focus 2. simpl in *.
        match goal with
          | [ H : applyD ?A ?B ?C ?D ?E = _ |- match ?X with _ => _ end ] =>
            change X with (applyD A B C D E); rewrite H
        end. eassumption.

        revert H; consider (exprD funcs uvars vars ve tvWord); intros; auto.
        unfold IL_ReadWord, ReadWord. simpl.
        eapply satisfies_get_word; eauto.
        eapply split_smem_get_word; eauto. }
      { eapply interp_satisfies in H4. think.
        apply satisfies_star in H5. think.
        eapply write_pred_correct in H; eauto.
        Focus 2. simpl in *.
        match goal with
          | [ H : applyD ?A ?B ?C ?D ?E = _ |- match ?X with _ => _ end ] =>
            change X with (applyD A B C D E); rewrite H
        end. eassumption.
        revert H.
        match goal with
          | [ |- match ?X with _ => _ end -> match ?Y with _ => _ end ] =>
            change X with Y; consider Y; intros; auto
        end.
        revert H8. consider (smem_set_word (explode stn) p v x); try contradiction; intros.
        unfold IL_WriteWord, WriteWord in *.
        eapply split_smem_set_word in H8; eauto. think.
        generalize H10.
        eapply satisfies_set_word in H10; eauto. think. 
        simpl in *. rewrite H12. intro.

        clear read_pred_correct write_pred_correct.
        eapply interp_satisfies; simpl. split.
        eapply memoryIn_sound.

        eapply satisfies_star.
        do 2 eexists. split; [ | split; eassumption ].

        erewrite <- same_domain_memoryIn; try eassumption.
        symmetry. etransitivity; try eassumption.
        
        eapply same_domain_memoryIn_mem_set_word in H12. symmetry. eauto. }
    Qed. 

    Variable predIndex : nat.

    Theorem MemPredEval_To_MemEvaluator_correct preds : 
      nth_error preds predIndex = Some pred ->
      @MEVAL.MemEvaluator_correct types pcT stT
      (@MEVAL.PredEval.MemEvalPred_to_MemEvaluator _ mep predIndex) funcs preds
      (IL.settings * IL.state) (tvType 0) (tvType 0) IL_mem_satisfies IL_ReadWord IL_WriteWord.
    Proof.
      intros.
      eapply MEVAL.PredEval.MemEvaluator_MemEvalPred_correct; simpl;
        try eauto using IL_mem_satisfies_himp, IL_mem_satisfies_pure, mep_correct.
      eassumption. eapply mep_correct.
      eauto using IL_mem_satisfies_himp.
      eapply IL_mem_satisfies_pure.
    Qed.

  End ForWord.

End spec_functions.

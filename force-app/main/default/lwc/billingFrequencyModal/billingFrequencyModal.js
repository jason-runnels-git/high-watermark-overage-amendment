import { LightningElement, api, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { NavigationMixin } from 'lightning/navigation';
import getContractsWithAssets from '@salesforce/apex/BillingFrequencyController.getContractsWithAssets';
import getExistingRenewalContracts from '@salesforce/apex/BillingFrequencyController.getExistingRenewalContracts';
import createRenewalContract from '@salesforce/apex/BillingFrequencyController.createRenewalContract';
import callRenewEndpoint from '@salesforce/apex/BillingFrequencyController.callRenewEndpoint';
import stampQuoteContract from '@salesforce/apex/BillingFrequencyController.stampQuoteContract';
import buildFreqChangeQuote from '@salesforce/apex/BillingFrequencyController.buildFreqChangeQuote';
import addFreqChangeLines from '@salesforce/apex/BillingFrequencyController.addFreqChangeLines';
import repriceFreqChangeQuote from '@salesforce/apex/BillingFrequencyController.repriceFreqChangeQuote';
import stampPostActivation from '@salesforce/apex/BillingFrequencyController.stampPostActivation';
import getQuoteCalculationStatus from '@salesforce/apex/BillingFrequencyController.getQuoteCalculationStatus';
import createOrderFromQuote from '@salesforce/apex/BillingFrequencyController.createOrderFromQuote';
import activateOrder from '@salesforce/apex/BillingFrequencyController.activateOrder';

export default class BillingFrequencyModal extends NavigationMixin(LightningElement) {
    @api recordId;

    @track currentStep = 1;
    @track contracts = [];
    @track selectedContractId;
    @track selectedContract;
    @track lineItems = [];
    @track renewalStartDate;
    @track renewalEndDate;
    @track renewalContractMode = 'auto';    // 'auto' | 'existing'
    @track existingRenewalContracts = [];
    @track selectedRenewalContractId = null;
    @track reviewAcknowledged = false;
    @track isLoading = true;
    @track isSubmitting = false;
    @track submittingStatus = '';
    @track completionMessage = '';
    @track errorMessage;

    _sessionId;
    _requestJson;

    // ─── Lifecycle ────────────────────────────────────────────────────────────

    connectedCallback() {
        window.addEventListener('message', this._handleMessage.bind(this));
        this._loadContracts();
    }

    disconnectedCallback() {
        window.removeEventListener('message', this._handleMessage.bind(this));
    }

    _handleMessage(event) {
        if (event.data?.sessionId) this._sessionId = event.data.sessionId;
    }

    handleIframeLoad() {}

    async _loadContracts() {
        this.isLoading = true;
        try {
            const data = await getContractsWithAssets({ accountId: this.recordId });
            this.contracts = (data || []).map(c => ({
                ...c,
                assetCount: (c.assets || []).length,
                endDateDisplay: c.endDate || 'Open-ended',
                isSelected: false,
                cardClass: 'slds-box slds-m-bottom_small asset-card'
            }));
        } catch (err) {
            this.errorMessage = 'Failed to load contracts: ' + (err.body?.message || err.message);
        }
        this.isLoading = false;
    }

    // ─── Getters ──────────────────────────────────────────────────────────────

    get isStep1() { return this.currentStep === 1; }
    get isStep2() { return this.currentStep === 2; }
    get isStep3() { return this.currentStep === 3; }
    get stepLabel() {
        if (this.currentStep === 1) return 'Select Contract';
        if (this.currentStep === 2) return 'Configure Frequency Changes';
        return 'Processing';
    }
    get noContracts() { return !this.isLoading && this.contracts.length === 0; }
    get isNextDisabled() { return !this.selectedContractId; }
    get isSubmitDisabled() {
        if (!this.renewalStartDate || !this.renewalEndDate || this.isSubmitting) return true;
        if (this.renewalContractMode === 'existing' && !this.selectedRenewalContractId) return true;
        if (this.hasAssetsNeedingReview && !this.reviewAcknowledged) return true;
        return false;
    }
    get submitLabel() { return this.isSubmitting ? 'Submitting...' : 'Create Renewal'; }
    get hasFreqChanges() { return this.lineItems.some(l => l.selectedPbeId); }
    get changedLineCount() { return this.lineItems.filter(l => l.selectedPbeId).length; }

    get renewalContractModeOptions() {
        return [
            { label: 'Auto-create a new renewal contract', value: 'auto' },
            { label: 'Use an existing contract', value: 'existing' }
        ];
    }
    get showExistingContractPicker() { return this.renewalContractMode === 'existing'; }
    get existingContractOptions() {
        return this.existingRenewalContracts.map(c => ({ label: c.label, value: c.contractId }));
    }
    get hasExistingContracts() { return this.existingRenewalContracts.length > 0; }

    get assetsNeedingReview() {
        return this.lineItems
            .filter(l => !l.selectedPbeId && l.needsAssetReview)
            .map(l => ({
                assetId: l.assetId,
                productName: l.productName,
                renewalTermDisplay:     l.renewalTerm     || '— missing',
                renewalTermUnitDisplay: l.renewalTermUnit || '— missing',
                pricingSourceDisplay:   l.pricingSource   || '— missing',
                renewalTermClass:     l.renewalTerm     ? 'slds-text-body_small' : 'slds-text-body_small review-missing',
                renewalTermUnitClass: l.renewalTermUnit ? 'slds-text-body_small' : 'slds-text-body_small review-missing',
                pricingSourceClass:   l.pricingSource   ? 'slds-text-body_small' : 'slds-text-body_small review-missing'
            }));
    }
    get hasAssetsNeedingReview() { return this.assetsNeedingReview.length > 0; }

    // ─── Step 1 ───────────────────────────────────────────────────────────────

    handleContractSelect(event) {
        const newId = event.currentTarget.dataset.id;
        if (newId === this.selectedContractId) return;
        this.selectedContractId = newId;
        this.contracts = this.contracts.map(c => ({
            ...c,
            isSelected: c.contractId === newId,
            cardClass: c.contractId === newId
                ? 'slds-box slds-m-bottom_small asset-card asset-card_selected'
                : 'slds-box slds-m-bottom_small asset-card'
        }));
        this.selectedContract = this.contracts.find(c => c.contractId === newId);
    }

    handleNext() {
        this.currentStep = 2;
        this.errorMessage = null;
        this.renewalContractMode = 'auto';
        this.selectedRenewalContractId = null;

        // Load existing renewal contract candidates in background
        getExistingRenewalContracts({
            sourceContractId: this.selectedContractId,
            accountId: this.recordId
        }).then(data => {
            this.existingRenewalContracts = (data || []).map(c => ({
                ...c,
                value: c.contractId
            }));
        }).catch(() => {
            // Non-fatal — existing contracts are optional
            this.existingRenewalContracts = [];
        });

        // Default renewal dates from contract lifecycle end + 1 day
        const assets = this.selectedContract?.assets || [];
        if (assets.length > 0 && assets[0].lifecycleEndDate && !this.renewalStartDate) {
            const end = new Date(assets[0].lifecycleEndDate + 'T00:00:00');
            const start = new Date(end.getFullYear(), end.getMonth(), end.getDate() + 1);
            this.renewalStartDate = start.toISOString().split('T')[0];
            // Default renewal end = 1 year after start
            const renewEnd = new Date(start.getFullYear() + 1, start.getMonth(), start.getDate() - 1);
            this.renewalEndDate = renewEnd.toISOString().split('T')[0];
        }

        // Build line items from selected contract assets
        this.lineItems = (this.selectedContract?.assets || []).map(a => {
            const rawOptions = a.upgradeOptions || [];
            const mappedOptions = rawOptions.map(o => ({
                label: o.label,
                value: o.pricebookEntryId
            }));
            return {
                ...a,
                selectedPbeId: null,
                selectedUnitPrice: null,
                needsAssetReview: a.needsAssetReview,
                renewalTerm: a.renewalTerm,
                pricingSource: a.pricingSource,
                upgradeOptions: mappedOptions,
                hasUpgradeOptions: mappedOptions.length > 0,   // derived from rebuilt array, not Apex Boolean
                _upgradeOptionsRaw: rawOptions
            };
        });
        this.reviewAcknowledged = false;
    }

    handleBack() {
        this.currentStep = 1;
        this.errorMessage = null;
        this.reviewAcknowledged = false;
    }

    // ─── Step 2 ───────────────────────────────────────────────────────────────

    handleStartDateChange(event) { this.renewalStartDate = event.detail.value; }
    handleEndDateChange(event) { this.renewalEndDate = event.detail.value; }

    handleContractModeChange(event) {
        this.renewalContractMode = event.detail.value;
        this.selectedRenewalContractId = null;
    }
    handleExistingContractChange(event) {
        this.selectedRenewalContractId = event.detail.value;
    }
    handleReviewAck(event) {
        this.reviewAcknowledged = event.target.checked;
    }

    handleFreqChange(event) {
        const assetId = event.currentTarget.dataset.id;
        const pbeId = event.detail.value;
        this.lineItems = this.lineItems.map(line => {
            if (line.assetId !== assetId) return line;
            const opt = (line._upgradeOptionsRaw || []).find(o => o.pricebookEntryId === pbeId);
            return {
                ...line,
                selectedPbeId: pbeId || null,
                selectedUnitPrice: opt ? opt.unitPrice : null,
                selectedPsmName: opt ? opt.psmName : null,
                selectedPricingTermUnit: opt ? opt.pricingTermUnit : null,
                selectedPsmId: opt ? opt.psmId : null
            };
        });
        this.errorMessage = null;
    }

    handleClose() { this.dispatchEvent(new CustomEvent('close')); }

    // ─── Submit ───────────────────────────────────────────────────────────────

    async handleSubmit() {
        this.errorMessage = null;
        if (!this._sessionId) {
            this.errorMessage = 'Session token not ready. Please wait a moment and try again.';
            return;
        }
        if (new Date(this.renewalEndDate) <= new Date(this.renewalStartDate)) {
            this.errorMessage = 'Renewal End Date must be after Renewal Start Date.';
            return;
        }

        this.currentStep = 3;
        this.isSubmitting = true;

        const lines = this.lineItems.map(line => ({
            assetId: line.assetId,
            product2Id: line.product2Id,
            productName: line.productName,
            quantity: line.currentQuantity,
            unitPrice: line.selectedUnitPrice,
            targetPricebookEntryId: line.selectedPbeId || null,
            targetPsmId: line.selectedPsmId || null,
            targetPsmName: line.selectedPsmName || null,
            targetPricingTermUnit: line.selectedPricingTermUnit || null,
            currentRenewalTermUnit: line.renewalTermUnit || null,
            needsAssetReview: !!line.needsAssetReview,
            frequencyChanged: !!line.selectedPbeId
        }));

        const request = {
            contractId: this.selectedContractId,
            renewalContractId: this.renewalContractMode === 'existing'
                ? this.selectedRenewalContractId : null,
            lines: lines,
            renewalStartDate: this.renewalStartDate,
            renewalEndDate: this.renewalEndDate
        };
        this._requestJson = JSON.stringify(request);

        try {
            // Step 1: DML — create/select renewal contract + obligations (no callout)
            this.submittingStatus = this.renewalContractMode === 'existing'
                ? 'Linking existing contract and creating obligations...'
                : 'Creating renewal contract and obligations...';
            const contractResult = await createRenewalContract({ requestJson: this._requestJson });
            const cp = JSON.parse(contractResult);
            if (!cp.ok) {
                this.errorMessage = cp.message;
                this.isSubmitting = false;
                return;
            }
            // Stash the renewal contract Id and inject it back into the request JSON
            this._renewalContractId = cp.contractId;
            const requestWithContract = JSON.parse(this._requestJson);
            requestWithContract.renewalContractId = cp.contractId;
            this._requestJson = JSON.stringify(requestWithContract);

            // Step 2: Callout — POST /amend (separate transaction, no pending DML)
            // /amend with quantityChange=0 generates an Amendment Quote that PST can operate on.
            this.submittingStatus = 'Generating billing frequency quote...';
            const renewResult = await callRenewEndpoint({
                sessionId: this._sessionId,
                requestJson: this._requestJson
            });
            const rp = JSON.parse(renewResult);
            if (!rp.ok) {
                this.errorMessage = rp.message;
                this.isSubmitting = false;
                return;
            }
            const renewalQuoteId = rp.quoteId; // null if all assets have freq changes

            // Step 3a: Resolve contract dates
            this.submittingStatus = 'Resolving contract dates...';
            const stampResult = await stampQuoteContract({
                sessionId: this._sessionId,
                quoteId: renewalQuoteId || '',
                contractId: this._renewalContractId,
                requestJson: this._requestJson
            });
            const sp = JSON.parse(stampResult);
            if (!sp.ok) {
                this.errorMessage = sp.message;
                this.isSubmitting = false;
                return;
            }
            const contractStartDate = sp.contractStartDate;
            const contractEndDate = sp.contractEndDate || '';

            // Step 3b: Build net-new freq-change quote (PST POST) for frequency-changed assets
            this.submittingStatus = 'Building billing frequency change quote...';
            const fcResult = await buildFreqChangeQuote({
                sessionId: this._sessionId,
                contractId: this._renewalContractId,
                contractStartDate,
                contractEndDate,
                requestJson: this._requestJson
            });
            const fc = JSON.parse(fcResult);
            if (!fc.ok) {
                this.errorMessage = 'Freq change quote failed: ' + (fc.message || fc.body);
                this.isSubmitting = false;
                return;
            }
            const freqQuoteId = fc.quoteId;

            // Step 3b-ii: Callout — add QSIs to the freq-change quote (separate tx from DML)
            if (freqQuoteId) {
                this.submittingStatus = 'Adding billing frequency lines...';
                await new Promise(resolve => setTimeout(resolve, 2000));
                const alResult = await addFreqChangeLines({
                    freqQuoteId,
                    contractStartDate,
                    contractEndDate,
                    requestJson: this._requestJson
                });
                const al = JSON.parse(alResult);
                if (!al.ok) {
                    this.errorMessage = 'Freq change quote failed: ' + (al.message || al.body);
                    this.isSubmitting = false;
                    return;
                }

                // Trigger pricing — DML-created quotes start with CalculationStatus=NotStarted
                this.submittingStatus = 'Triggering pricing on billing frequency quote...';
                await new Promise(resolve => setTimeout(resolve, 1000));
                const rpResult = await repriceFreqChangeQuote({
                    sessionId: this._sessionId,
                    freqQuoteId
                });
                const rpr = JSON.parse(rpResult);
                if (!rpr.ok) {
                    this.errorMessage = 'Reprice failed: ' + rpr.message;
                    this.isSubmitting = false;
                    return;
                }
            }

            const orderNumbers = [];

            // ─── Process renewal quote (unchanged assets) ─────────────────
            if (renewalQuoteId) {
                this.submittingStatus = 'Waiting for renewal quote pricing...';
                const MAX_POLLS = 20;
                for (let i = 0; i < MAX_POLLS; i++) {
                    const s = await getQuoteCalculationStatus({ quoteId: renewalQuoteId });
                    if (['Completed','CompletedWithPricing','CompletedWithTax','NotFound'].includes(s)) break;
                    if (i === MAX_POLLS - 1) {
                        this.errorMessage = 'Renewal quote pricing timed out (' + s + '). Reprice manually.';
                        this.isSubmitting = false;
                        return;
                    }
                    await new Promise(r => setTimeout(r, 2000));
                }
                this.submittingStatus = 'Activating renewal order...';
                const ro = JSON.parse(await createOrderFromQuote({ quoteId: renewalQuoteId }));
                if (!ro.ok) { this.errorMessage = 'Renewal order creation failed: ' + ro.message; this.isSubmitting = false; return; }
                const ra = JSON.parse(await activateOrder({ orderId: ro.orderId, renewalContractId: this._renewalContractId, effectiveDate: contractStartDate }));
                if (!ra.ok) { this.errorMessage = 'Renewal order activation failed: ' + (ra.message || ra.body); this.isSubmitting = false; return; }
                orderNumbers.push(ra.orderNumber);
            }

            // ─── Process freq-change quote ─────────────────────────────────
            if (freqQuoteId) {
                this.submittingStatus = 'Waiting for billing frequency quote pricing...';
                const MAX_POLLS = 20;
                for (let i = 0; i < MAX_POLLS; i++) {
                    const s = await getQuoteCalculationStatus({ quoteId: freqQuoteId });
                    if (['Completed','CompletedWithPricing','CompletedWithTax','NotFound'].includes(s)) break;
                    if (i === MAX_POLLS - 1) {
                        this.errorMessage = 'Freq change quote pricing timed out (' + s + '). Reprice manually.';
                        this.isSubmitting = false;
                        return;
                    }
                    await new Promise(r => setTimeout(r, 2000));
                }
                this.submittingStatus = 'Activating billing frequency order...';
                const fo = JSON.parse(await createOrderFromQuote({ quoteId: freqQuoteId }));
                if (!fo.ok) { this.errorMessage = 'Freq change order creation failed: ' + fo.message; this.isSubmitting = false; return; }
                // Freq-change order: set EffectiveDate = renewal contract start date
                // so assets get correct lifecycle dates and auto-link to renewal contract via ACR
                const fa = JSON.parse(await activateOrder({ orderId: fo.orderId, renewalContractId: this._renewalContractId, effectiveDate: contractStartDate }));
                if (!fa.ok) { this.errorMessage = 'Freq change order activation failed: ' + (fa.message || fa.body); this.isSubmitting = false; return; }
                orderNumbers.push(fa.orderNumber);
            }

            // Step 6: Post-activation — create dual ACR for unchanged assets → renewal contract
            this.submittingStatus = 'Finalizing contract associations...';
            await stampPostActivation({
                renewalContractId: this._renewalContractId,
                requestJson: this._requestJson
            });

            this.isSubmitting = false;
            this.completionMessage = 'Orders activated: ' + orderNumbers.join(', ') + ' · Contract and obligations recorded.';

            this.dispatchEvent(new ShowToastEvent({
                title: 'Billing Frequency Change Complete',
                message: 'Orders ' + orderNumbers.join(', ') + ' activated. New frequencies take effect at renewal.',
                variant: 'success',
                mode: 'sticky'
            }));

            this[NavigationMixin.Navigate]({
                type: 'standard__recordPage',
                attributes: { recordId: this._renewalContractId, actionName: 'view' }
            });

        } catch (err) {
            this.errorMessage = 'Error: ' + (err.body?.message || err.message);
            this.isSubmitting = false;
        }
    }
}
